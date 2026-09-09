import FluidAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let clips = Array(CommandLine.arguments.dropFirst())
guard !clips.isEmpty else {
    fail("usage: FluidAudioBench <clip.wav> [clip2.wav ...]   (run from repo root)")
}

let modelDir = URL(fileURLWithPath: "models/parakeet-tdt-0.6b-v2", isDirectory: true)
guard AsrModels.modelsExist(at: modelDir) else {
    fail("CoreML model files missing or incomplete at \(modelDir.path)")
}

// All model files are staged locally; refuse any network fetch.
ModelHub.offlineMode = true

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

let clock = ContinuousClock()

let loadStart = clock.now
let models: AsrModels
do {
    models = try await AsrModels.load(from: modelDir, version: .v2)
} catch {
    fail("Failed to load CoreML models: \(error)")
}
let asr = AsrManager(config: .default, models: models)
print(String(format: "model-load: %.3f s", seconds(clock.now - loadStart)))

for clip in clips {
    let samples: [Float]
    do {
        samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: clip))
    } catch {
        fail("Failed to read/resample \(clip): \(error)")
    }
    print("--- \(clip)")
    for run in 1...3 {
        do {
            var state = try TdtDecoderState(decoderLayers: 2)
            let start = clock.now
            let result = try await asr.transcribe(samples, decoderState: &state)
            let elapsed = seconds(clock.now - start)
            print(String(format: "run %d: %.3f s | %@", run, elapsed, result.text))
        } catch {
            fail("Transcription failed on \(clip): \(error)")
        }
    }
}
