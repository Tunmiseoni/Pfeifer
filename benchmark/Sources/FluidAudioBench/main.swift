import AVFoundation
import FluidAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

enum ModelKind: String {
    case v2
    case unified
}

// --- arguments -------------------------------------------------------------

var modelKind = ModelKind.unified
var stream = false
var clips: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--model":
        guard let value = args.first else { fail("--model requires a value: v2|unified") }
        args.removeFirst()
        guard let kind = ModelKind(rawValue: value.lowercased()) else {
            fail("unknown model '\(value)' (expected v2 or unified)")
        }
        modelKind = kind
    case "--stream":
        stream = true
    default:
        if arg.hasPrefix("--") { fail("unknown flag \(arg)") }
        clips.append(arg)
    }
}

guard !clips.isEmpty else {
    fail("usage: FluidAudioBench [--model v2|unified] [--stream] <clip.wav> [...]   (run from repo root)")
}
if stream && modelKind != .unified {
    fail("--stream requires --model unified")
}

// All model files are staged locally; refuse any network fetch.
ModelHub.offlineMode = true

let clock = ContinuousClock()

func loadClips() throws -> [(path: String, samples: [Float])] {
    var loaded: [(path: String, samples: [Float])] = []
    for clip in clips {
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: clip))
        loaded.append((clip, samples))
    }
    return loaded
}

// --- v2: Parakeet TDT 0.6B v2 (Phase 0 baseline) ----------------------------

if modelKind == .v2 {
    let modelDir = URL(fileURLWithPath: "models/parakeet-tdt-0.6b-v2", isDirectory: true)
    guard AsrModels.modelsExist(at: modelDir) else {
        fail("CoreML model files missing or incomplete at \(modelDir.path)")
    }

    let audio = try loadClips()

    let loadStart = clock.now
    let models: AsrModels
    do {
        models = try await AsrModels.load(from: modelDir, version: .v2)
    } catch {
        fail("Failed to load CoreML models: \(error)")
    }
    let asr = AsrManager(config: .default, models: models)
    print(String(format: "model-load: %.3f s", seconds(clock.now - loadStart)))

    for clip in audio {
        print("--- \(clip.path)")
        for run in 1...3 {
            do {
                var state = try TdtDecoderState(decoderLayers: 2)
                let start = clock.now
                let result = try await asr.transcribe(clip.samples, decoderState: &state)
                let elapsed = seconds(clock.now - start)
                print(String(format: "run %d: %.3f s | %@", run, elapsed, result.text))
            } catch {
                fail("Transcription failed on \(clip.path): \(error)")
            }
        }
    }
    exit(0)
}

// --- unified: Parakeet Unified EN 0.6B ---------------------------------------

let unifiedDir = URL(fileURLWithPath: "models/parakeet-unified-en-0.6b", isDirectory: true)

let requiredUnifiedFiles: [String] =
    stream
    ? [
        "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc",
        "parakeet_unified_decoder.mlmodelc",
        "parakeet_unified_joint_decision_single_step.mlmodelc",
        "vocab.json",
    ]
    : [
        "parakeet_unified_encoder_int8.mlmodelc",
        "parakeet_unified_decoder.mlmodelc",
        "parakeet_unified_joint_decision_single_step.mlmodelc",
        "vocab.json",
    ]

let fileManager = FileManager.default
for name in requiredUnifiedFiles {
    guard fileManager.fileExists(atPath: unifiedDir.appendingPathComponent(name).path) else {
        fail("Unified model file missing at \(unifiedDir.path)/\(name)")
    }
}

let audio = try loadClips()

if stream {
    // 320 ms fast-feel tier: [70, 2, 2] = 5.6 s left, 160 ms chunk, 160 ms right.
    let config = UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2)
    let manager = StreamingUnifiedAsrManager(config: config)

    let loadStart = clock.now
    do {
        try await manager.loadModels(from: unifiedDir)
    } catch {
        fail("Failed to load Unified streaming models: \(error)")
    }
    print(
        String(
            format: "model-load: %.3f s (streaming, %d ms tier)",
            seconds(clock.now - loadStart), config.latencyMs))

    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    for clip in audio {
        print("--- \(clip.path)")
        try await manager.reset()

        let samples = clip.samples
        let chunkSamples = config.chunkSamples
        let audioSeconds = Double(samples.count) / Double(config.sampleRate)
        print(String(format: "audio: %.1f s (%d chunks of %d samples)", audioSeconds, (samples.count + chunkSamples - 1) / chunkSamples, chunkSamples))

        var chunkMillis: [Double] = []
        var partials: [(afterSeconds: Double, text: String)] = []
        let feedStart = clock.now
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSamples, samples.count)
            let count = end - offset
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples[offset..<end].withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: count)
            }
            let chunkStart = clock.now
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
            chunkMillis.append(seconds(clock.now - chunkStart) * 1000)
            offset = end
            if offset.isMultiple(of: chunkSamples * 25) {
                partials.append(
                    (Double(offset) / Double(config.sampleRate), await manager.getPartialTranscript()))
            }
        }
        let partial = await manager.getPartialTranscript()
        let final = try await manager.finish()
        let feedElapsed = seconds(clock.now - feedStart)

        let sorted = chunkMillis.sorted()
        let avg = chunkMillis.reduce(0, +) / Double(chunkMillis.count)
        print(
            String(
                format: "chunks: %d | per-chunk min/avg/max: %.1f / %.1f / %.1f ms",
                chunkMillis.count, sorted.first ?? 0, avg, sorted.last ?? 0))
        print(
            String(
                format: "wall: %.3f s for %.1f s audio (%.1fx real-time)",
                feedElapsed, audioSeconds, feedElapsed > 0 ? audioSeconds / feedElapsed : 0))
        for snapshot in partials {
            print(String(format: "partial @ %5.1f s | %@", snapshot.afterSeconds, snapshot.text))
        }
        print("partial-before-flush | \(partial)")
        print("final | \(final)")
    }
    exit(0)
}

// Batch: offline full-attention encoder, overlapping 15 s windows.
let manager = UnifiedAsrManager()
let loadStart = clock.now
do {
    try await manager.loadModels(from: unifiedDir)
} catch {
    fail("Failed to load Unified models: \(error). If this is an int8 encoder plan failure, the fp16 encoder is the documented fallback (issue #828).")
}
print(String(format: "model-load: %.3f s", seconds(clock.now - loadStart)))

for clip in audio {
    print("--- \(clip.path)")
    for run in 1...3 {
        do {
            let start = clock.now
            let text = try await manager.transcribe(clip.samples)
            let elapsed = seconds(clock.now - start)
            print(String(format: "run %d: %.3f s | %@", run, elapsed, text))
        } catch {
            fail("Transcription failed on \(clip.path): \(error)")
        }
    }
}
