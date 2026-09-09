import AVFoundation
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3,
      let seconds = Double(args[2]),
      seconds > 0,
      seconds <= 600
else {
    fail("usage: ClipRecorder <out.wav> <seconds>   (records 16 kHz mono 16-bit PCM)")
}
let outURL = URL(fileURLWithPath: args[1])

try? FileManager.default.removeItem(at: outURL)

let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 16_000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]

let recorder: AVAudioRecorder
do {
    recorder = try AVAudioRecorder(url: outURL, settings: settings)
} catch {
    fail("Failed to create recorder: \(error)")
}

guard recorder.record(forDuration: seconds) else {
    fail("Recording failed to start. If macOS asked for microphone permission and you denied it, grant it in System Settings > Privacy & Security > Microphone for this terminal app, then re-run.")
}
print("Recording \(Int(seconds))s — speak now…")
fflush(stdout)

let deadline = Date().addingTimeInterval(seconds + 5)
while recorder.isRecording, Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
}
recorder.stop()

let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path)
let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
guard size > 44 else {
    fail("Recorded file is empty — microphone permission was likely denied. Grant it in System Settings > Privacy & Security > Microphone for this terminal app, then re-run.")
}

// Detect digital silence (all-zero samples): the signature of a denied
// microphone permission, where macOS delivers zeros instead of failing.
do {
    let data = try Data(contentsOf: outURL)
    guard data.count > 44 else { fail("Recorded file too small.") }
    var offset = 12
    var audioData = Data()
    while offset + 8 <= data.count {
        let chunkID = String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii) ?? ""
        let chunkSize = Int(data[data.startIndex + offset + 4])
            | (Int(data[data.startIndex + offset + 5]) << 8)
            | (Int(data[data.startIndex + offset + 6]) << 16)
            | (Int(data[data.startIndex + offset + 7]) << 24)
        if chunkID == "data" {
            audioData = data.subdata(in: (offset + 8)..<min(offset + 8 + chunkSize, data.count))
            break
        }
        offset = offset + 8 + chunkSize + (chunkSize % 2)
    }
    var nonzero = false
    if !audioData.isEmpty {
        audioData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in stride(from: 0, to: raw.count - 1, by: 2) {
                if raw[i] != 0 || raw[i + 1] != 0 {
                    nonzero = true
                    break
                }
            }
        }
    }
    guard nonzero else {
        fail("Recording captured digital silence (all samples zero) — the microphone permission was not actually granted to this process. Run this command from your own terminal app (so macOS shows the mic prompt) or grant permission in System Settings > Privacy & Security > Microphone.")
    }
} catch {
    fail("Could not verify recording contents: \(error)")
}
print("Saved \(outURL.path) (\(size) bytes)")
