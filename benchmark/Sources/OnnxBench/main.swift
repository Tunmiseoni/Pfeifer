import Foundation
import OnnxRuntimeBindings

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let modelDir = "models/parakeet-tdt-0.6b-v2-onnx-int8"
let preprocessorPath = "\(modelDir)/nemo128.onnx"
let encoderPath = "\(modelDir)/encoder-model.int8.onnx"
let jointPath = "\(modelDir)/decoder_joint-model.int8.onnx"

var useCPU = false
var clips: [String] = []
for arg in Array(CommandLine.arguments.dropFirst()) {
    if arg == "--cpu" {
        useCPU = true
    } else if arg == "--inspect" {
        clips = []
        break
    } else {
        clips.append(arg)
    }
}
let inspectOnly = clips.isEmpty

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

// MARK: - WAV reading (PCM 16-bit or float 32-bit; first channel; must be 16 kHz)

struct Wav {
    let samples: [Float]
    let sampleRate: Int
}

func readU16(_ data: Data, _ offset: Int) -> Int {
    Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
}

func readU32(_ data: Data, _ offset: Int) -> Int {
    readU16(data, offset) | (readU16(data, offset + 2) << 16)
}

func readWav(path: String) throws -> Wav {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count >= 44,
          String(data: data.prefix(4), encoding: .ascii) == "RIFF",
          String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE"
    else {
        throw NSError(domain: "Wav", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "\(path): not a RIFF/WAVE file"])
    }

    var formatTag = 0, channels = 0, sampleRate = 0, bitsPerSample = 0
    var audioData = Data()
    var offset = 12
    while offset + 8 <= data.count {
        let chunkID = String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii) ?? ""
        let chunkSize = readU32(data, offset + 4)
        let bodyStart = offset + 8
        let bodyEnd = min(bodyStart + chunkSize, data.count)
        if chunkID == "fmt " {
            guard chunkSize >= 16 else { throw NSError(domain: "Wav", code: 2) }
            formatTag = readU16(data, bodyStart)
            channels = readU16(data, bodyStart + 2)
            sampleRate = readU32(data, bodyStart + 4)
            bitsPerSample = readU16(data, bodyStart + 14)
        } else if chunkID == "data" {
            audioData = data.subdata(in: bodyStart..<bodyEnd)
        }
        offset = bodyStart + chunkSize + (chunkSize % 2)
    }

    guard formatTag == 1 || formatTag == 3, channels >= 1, !audioData.isEmpty else {
        throw NSError(domain: "Wav", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(path): unsupported WAV layout (format=\(formatTag), channels=\(channels))"])
    }
    guard sampleRate == 16_000 else {
        throw NSError(domain: "Wav", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "\(path): expected 16 kHz, got \(sampleRate)"])
    }

    var samples: [Float] = []
    if formatTag == 1, bitsPerSample == 16 {
        samples.reserveCapacity(audioData.count / 2 / channels)
        var i = 0
        while i + 2 * channels <= audioData.count {
            let lo = Int(audioData[audioData.startIndex + i])
            let hi = Int(audioData[audioData.startIndex + i + 1])
            samples.append(Float(Int16(bitPattern: UInt16(lo | (hi << 8)))) / 32768.0)
            i += 2 * channels
        }
    } else if formatTag == 3, bitsPerSample == 32 {
        samples.reserveCapacity(audioData.count / 4 / channels)
        var i = 0
        while i + 4 * channels <= audioData.count {
            audioData.subdata(in: i..<(i + 4)).withUnsafeBytes { raw in
                samples.append(raw.load(as: Float.self))
            }
            i += 4 * channels
        }
    } else {
        throw NSError(domain: "Wav", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "\(path): unsupported PCM variant (format=\(formatTag), bits=\(bitsPerSample))"])
    }
    return Wav(samples: samples, sampleRate: sampleRate)
}

// MARK: - ORT plumbing

let env: ORTEnv
do {
    env = try ORTEnv(loggingLevel: .warning)
} catch {
    fail("Failed to create ORTEnv: \(error)")
}

func makeSession(path: String) throws -> ORTSession {
    let options = try ORTSessionOptions()
    if !useCPU {
        try options.appendExecutionProvider("CoreML", providerOptions: [:])
    }
    return try ORTSession(env: env, modelPath: path, sessionOptions: options)
}

func floatTensor(_ values: [Float], _ shape: [Int]) throws -> ORTValue {
    try values.withUnsafeBytes { raw in
        try ORTValue(tensorData: NSMutableData(bytes: raw.baseAddress, length: raw.count),
                     elementType: .float,
                     shape: shape.map { NSNumber(value: $0) })
    }
}

func int64Tensor(_ values: [Int64], _ shape: [Int]) throws -> ORTValue {
    try values.withUnsafeBytes { raw in
        try ORTValue(tensorData: NSMutableData(bytes: raw.baseAddress, length: raw.count),
                     elementType: .int64,
                     shape: shape.map { NSNumber(value: $0) })
    }
}

func int32Tensor(_ values: [Int32], _ shape: [Int]) throws -> ORTValue {
    try values.withUnsafeBytes { raw in
        try ORTValue(tensorData: NSMutableData(bytes: raw.baseAddress, length: raw.count),
                     elementType: .int32,
                     shape: shape.map { NSNumber(value: $0) })
    }
}

func floats(from value: ORTValue) throws -> [Float] {
    let data = try value.tensorData()
    let ptr = data.bytes.assumingMemoryBound(to: Float.self)
    return Array(UnsafeBufferPointer(start: ptr, count: data.length / 4))
}

func int64s(from value: ORTValue) throws -> [Int64] {
    let data = try value.tensorData()
    let ptr = data.bytes.assumingMemoryBound(to: Int64.self)
    return Array(UnsafeBufferPointer(start: ptr, count: data.length / 8))
}

func shape(of value: ORTValue) throws -> [Int] {
    try value.tensorTypeAndShapeInfo().shape.map { $0.intValue }
}

func describe(_ session: ORTSession, label: String) {
    let inputs = (try? session.inputNames()) ?? ["<inputNames failed>"]
    let outputs = (try? session.outputNames()) ?? ["<outputNames failed>"]
    print("\(label):")
    print("  inputs : \(inputs.joined(separator: ", "))")
    print("  outputs: \(outputs.joined(separator: ", "))")
}

// MARK: - Joint state-shape probing (ObjC API exposes no input metadata, so probe)

func probeJointStateShapes(joint: ORTSession, encoderDim: Int) throws -> (Int, Int, Int, Int) {
    var s1a = 1, s1b = 1, s2a = 1, s2b = 1
    for _ in 0..<6 {
        let probeInputs: [String: ORTValue] = [
            "encoder_outputs": try floatTensor([Float](repeating: 0, count: encoderDim), [1, encoderDim, 1]),
            "targets": try int32Tensor([1024], [1, 1]),
            "target_length": try int32Tensor([1], [1]),
            "input_states_1": try floatTensor([Float](repeating: 0, count: s1a * s1b), [s1a, 1, s1b]),
            "input_states_2": try floatTensor([Float](repeating: 0, count: s2a * s2b), [s2a, 1, s2b]),
        ]
        do {
            // Ran without error — read back the authoritative state shapes.
            let out = try joint.run(
                withInputs: probeInputs,
                outputNames: ["outputs", "output_states_1", "output_states_2"], runOptions: nil)
            if let o1 = out["output_states_1"] {
                let sh = try shape(of: o1)
                if sh.count == 3 { s1a = sh[0]; s1b = sh[2] }
            }
            if let o2 = out["output_states_2"] {
                let sh = try shape(of: o2)
                if sh.count == 3 { s2a = sh[0]; s2b = sh[2] }
            }
            return (s1a, s1b, s2a, s2b)
        } catch {
            let message = "\(error)"
            let failed: String?
            if let r = message.range(of: "input: input_states_1") ?? message.range(of: "input: input_states_2") {
                failed = String(message[r])
            } else {
                failed = nil
            }
            guard let failed, failed.contains("input_states") else {
                fail("Joint probe: unexpected error: \(message)")
            }
            // Multi-line format: "index: N Got: X Expected: Y" per bad dimension.
            var dims: [Int: Int] = [:]
            let ns = message as NSString
            let linePattern = try NSRegularExpression(pattern: "index: (\\d+) Got: (\\d+) Expected: (\\d+)")
            for m in linePattern.matches(in: message, range: NSRange(location: 0, length: ns.length)) {
                let idx = Int(ns.substring(with: m.range(at: 1))) ?? -1
                let exp = Int(ns.substring(with: m.range(at: 3))) ?? -1
                if idx >= 0, exp > 0 { dims[idx] = exp }
            }
            if dims.isEmpty, let r = message.range(of: #"expected:? \[([\d, ]+)\]"#, options: .regularExpression) {
                // Bracketed fallback: "expected: [a, b, c]"
                let nums = message[r].components(separatedBy: CharacterSet(charactersIn: "[] ,")).compactMap { Int($0) }
                if nums.count == 3 { dims = [0: nums[0], 1: nums[1], 2: nums[2]] }
            }
            guard let d0 = dims[0], let d2 = dims[2] else {
                fail("Joint probe: could not parse expected shape from: \(message)")
            }
            if failed.contains("input_states_1") {
                s1a = d0; s1b = d2
            } else {
                s2a = d0; s2b = d2
            }
        }
    }
    fail("Joint probe: did not converge")
}

// MARK: - Vocabulary

let vocab: [String]
do {
    let text = try String(contentsOfFile: "\(modelDir)/vocab.txt", encoding: .utf8)
    var entries = [String](repeating: "", count: 1025)
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let id = Int(parts[1]) else { continue }
        if id < 1025 {
            entries[id] = String(parts[0]).replacingOccurrences(of: "\u{2581}", with: " ")
        }
    }
    vocab = entries
} catch {
    fail("Failed to read vocab.txt: \(error)")
}
let vocabSize = 1025
let blankIdx = 1024

func detokenize(_ ids: [Int]) -> String {
    let joined = ids.map { vocab[$0] }.joined()
    let nsText = joined as NSString
    let regex = try! NSRegularExpression(pattern: #"\A\s|\s\B|(\s)\b"#)
    let matches = regex.matches(in: joined, range: NSRange(location: 0, length: nsText.length))
    var result = ""
    var lastEnd = 0
    for match in matches {
        if match.range.location > lastEnd {
            result += nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
        }
        if match.range(at: 1).location != NSNotFound {
            result += " "
        }
        lastEnd = match.range.location + match.range.length
    }
    if lastEnd < nsText.length {
        result += nsText.substring(from: lastEnd)
    }
    return result
}

// MARK: - Main

let clock = ContinuousClock()

guard FileManager.default.fileExists(atPath: preprocessorPath) else {
    fail("Missing \(preprocessorPath)")
}
let preprocessor: ORTSession
do {
    preprocessor = try makeSession(path: preprocessorPath)
} catch {
    fail("Failed to load preprocessor: \(error)")
}

guard FileManager.default.fileExists(atPath: jointPath) else {
    fail("Missing \(jointPath)")
}
let joint: ORTSession
do {
    joint = try makeSession(path: jointPath)
} catch {
    fail("Failed to load decoder_joint: \(error)")
}

var encoder: ORTSession?
if FileManager.default.fileExists(atPath: encoderPath) {
    do {
        encoder = try makeSession(path: encoderPath)
    } catch {
        fail("Failed to load encoder: \(error)")
    }
} else {
    print("note: \(encoderPath) not present yet — encoder-dependent steps unavailable")
}

if inspectOnly {
    describe(preprocessor, label: "nemo128.onnx")
    if let encoder { describe(encoder, label: "encoder-model.int8.onnx") }
    describe(joint, label: "decoder_joint-model.int8.onnx")
    if let encoder {
        let (s1a, s1b, s2a, s2b) = try probeJointStateShapes(joint: joint, encoderDim: 1024)
        print("joint state shapes: input_states_1=[\(s1a), 1, \(s1b)] input_states_2=[\(s2a), 1, \(s2b)]")
    }
    exit(0)
}

guard let encoder else {
    fail("Encoder model missing — cannot run pipeline")
}

let loadStart = clock.now
let (s1a, s1b, s2a, s2b) = try probeJointStateShapes(joint: joint, encoderDim: 1024)
print("session-load: \(String(format: "%.3f", seconds(clock.now - loadStart))) s (CoreML \(useCPU ? "OFF" : "requested"))")
print("joint states: [\(s1a), 1, \(s1b)] / [\(s2a), 1, \(s2b)]")

for clip in clips {
    let wav: Wav
    do {
        wav = try readWav(path: clip)
    } catch {
        fail("\(error.localizedDescription)")
    }
    print("--- \(clip) (\(wav.samples.count) samples, \(String(format: "%.1f", Double(wav.samples.count) / 16000.0))s)")

    for run in 1...3 {
        let totalStart = clock.now

        let tPre = clock.now
        let waveforms = try floatTensor(wav.samples, [1, wav.samples.count])
        let waveformsLens = try int64Tensor([Int64(wav.samples.count)], [1])
        let preOut = try preprocessor.run(
            withInputs: ["waveforms": waveforms, "waveforms_lens": waveformsLens],
            outputNames: ["features", "features_lens"], runOptions: nil)
        guard let features = preOut["features"], let featuresLens = preOut["features_lens"] else {
            fail("Preprocessor did not return expected outputs")
        }
        let melShape = try shape(of: features)
        let melLensValue = try int64s(from: featuresLens)[0]
        let preElapsed = seconds(clock.now - tPre)

        let tEnc = clock.now
        let lengthTensor = try int64Tensor([melLensValue], [1])
        let encOut = try encoder.run(
            withInputs: ["audio_signal": features, "length": lengthTensor],
            outputNames: ["outputs", "encoded_lengths"], runOptions: nil)
        guard let encoderOut = encOut["outputs"], let encodedLengths = encOut["encoded_lengths"] else {
            fail("Encoder did not return expected outputs")
        }
        let encShape = try shape(of: encoderOut)
        let encLen = Int(try int64s(from: encodedLengths)[0])
        let encElapsed = seconds(clock.now - tEnc)
        // Raw layout [B, D, T]; onnx-asr transposes to frames [T][D] before the joint.
        guard encShape.count == 3, encShape[1] == 1024 else {
            fail("Unexpected encoder output shape \(encShape) — expected [1, 1024, T]")
        }
        let encT = encShape[2]
        let encFlat = try floats(from: encoderOut)

        let tDec = clock.now
        var t = 0
        var emitted = 0
        var last = blankIdx
        var state1 = [Float](repeating: 0, count: s1a * s1b)
        var state2 = [Float](repeating: 0, count: s2a * s2b)
        var ids: [Int] = []
        var frame = [Float](repeating: 0, count: 1024)
        while t < encLen {
            for d in 0..<1024 {
                frame[d] = encFlat[d * encT + t]
            }
            let out = try joint.run(
                withInputs: [
                    "encoder_outputs": try floatTensor(frame, [1, 1024, 1]),
                    "targets": try int32Tensor([Int32(last)], [1, 1]),
                    "target_length": try int32Tensor([1], [1]),
                    "input_states_1": try floatTensor(state1, [s1a, 1, s1b]),
                    "input_states_2": try floatTensor(state2, [s2a, 1, s2b]),
                ],
                outputNames: ["outputs", "output_states_1", "output_states_2"], runOptions: nil)
            guard let outValue = out["outputs"] else {
                fail("Joint did not return outputs")
            }
            let o = try floats(from: outValue)
            guard o.count >= vocabSize else {
                fail("Joint output too small: \(o.count)")
            }
            var best = 0
            var bestValue: Float = -.infinity
            for i in 0..<vocabSize where o[i] > bestValue {
                bestValue = o[i]
                best = i
            }
            var step = 0
            var stepValue: Float = -.infinity
            for i in vocabSize..<o.count where o[i] > stepValue {
                stepValue = o[i]
                step = i - vocabSize
            }
            if best != blankIdx {
                if let ns1 = out["output_states_1"], let ns2 = out["output_states_2"] {
                    state1 = try floats(from: ns1)
                    state2 = try floats(from: ns2)
                }
                ids.append(best)
                last = best
                emitted += 1
            }
            if step > 0 {
                t += step
                emitted = 0
            } else if best == blankIdx || emitted >= 10 {
                t += 1
                emitted = 0
            }
        }
        let decElapsed = seconds(clock.now - tDec)
        let totalElapsed = seconds(clock.now - totalStart)

        print(String(format: "run %d: total %.3f s (pre %.3f / enc %.3f / dec %.3f) | %@",
                     run, totalElapsed, preElapsed, encElapsed, decElapsed, detokenize(ids)))
    }
}
