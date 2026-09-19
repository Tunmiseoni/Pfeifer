@preconcurrency import AVFoundation
@testable import pfeiferCore
import Testing

@Suite
struct RecorderConversionTests {
    /// Build a mono Float32 buffer of `frames` samples at `sampleRate`,
    /// filled with a deterministic pattern.
    private func makeBuffer(
        frames: AVAudioFrameCount,
        sampleRate: Double,
        fill: (Int) -> Float
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            channel[frame] = fill(frame)
        }
        return buffer
    }

    /// A 440 Hz sine at `sampleRate`, as a fill function.
    private func tone(sampleRate: Double) -> (Int) -> Float {
        { frame in
            let t: Double = Double(frame) / sampleRate
            let value: Double = sin(2.0 * Double.pi * 440.0 * t)
            return Float(value)
        }
    }

    private func makeConverter(from sampleRate: Double) -> AVAudioConverter {
        let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        return AVAudioConverter(from: input, to: Recorder.outputFormat)!
    }

    @Test
    func passthroughKeepsSampleCountAndValues() {
        // 16 kHz → 16 kHz: identity conversion, samples must survive intact.
        let converter = makeConverter(from: 16_000)
        let frames: AVAudioFrameCount = 1000
        let buffer = makeBuffer(frames: frames, sampleRate: 16_000) { frame in
            let value: Double = sin(Double(frame) * 0.01) * 0.5
            return Float(value)
        }

        let samples = Recorder.convert(buffer: buffer, with: converter)

        #expect(samples.count == Int(frames))
        let original = UnsafeBufferPointer(
            start: buffer.floatChannelData![0],
            count: 10
        )
        #expect(Array(samples.prefix(10)) == Array(original))
    }

    @Test
    func downsampleHalvesLength() {
        // 32 kHz → 16 kHz: length ≈ half. The converter is stream-oriented:
        // without an .endOfStream signal it keeps the resampler's filter
        // tail buffered, so up to ~300 samples (the tail budget) may be
        // pending rather than emitted. Content checks below carry the
        // correctness weight; the count check guards gross loss.
        let converter = makeConverter(from: 32_000)
        let frames: AVAudioFrameCount = 4000
        let buffer = makeBuffer(frames: frames, sampleRate: 32_000, fill: tone(sampleRate: 32_000))

        let samples = Recorder.convert(buffer: buffer, with: converter)

        #expect(samples.count >= Int(frames) / 2 - 300)
        #expect(samples.count <= Int(frames) / 2 + 16)
        // A 440 Hz tone downsampled stays a 440 Hz tone: rough energy check.
        let energy: Double = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms: Double = sqrt(energy / Double(samples.count))
        #expect(rms > 0.4 && rms < 0.8)
    }

    @Test
    func typicalMicRateProducesNonEmptyOutput() {
        // The real input path: 48 kHz mic → 16 kHz, typical tap buffer size.
        let converter = makeConverter(from: 48_000)
        let frames: AVAudioFrameCount = 4096
        let buffer = makeBuffer(frames: frames, sampleRate: 48_000, fill: tone(sampleRate: 48_000))

        let samples = Recorder.convert(buffer: buffer, with: converter)

        #expect(abs(samples.count - 4096 / 3) <= 8)
    }

    @Test
    func silenceProducesSilence() {
        // Stream-oriented converter: the resampler's tail (~up to 300
        // samples) stays buffered without an .endOfStream flush; in the real
        // Recorder it carries into the next tap buffer.
        let converter = makeConverter(from: 48_000)
        let buffer = makeBuffer(frames: 4800, sampleRate: 48_000) { _ in 0 }

        let samples = Recorder.convert(buffer: buffer, with: converter)

        #expect(samples.count >= 1600 - 300)
        #expect(samples.count <= 1616)
        #expect(samples.allSatisfy { $0 == 0 })
    }

    @Test
    func emptyBufferProducesNothing() {
        let converter = makeConverter(from: 48_000)
        let buffer = makeBuffer(frames: 0, sampleRate: 48_000) { _ in 0.5 }

        let samples = Recorder.convert(buffer: buffer, with: converter)

        #expect(samples.isEmpty)
    }
}

@Suite
struct RecorderStateTests {
    @Test
    func stopWithoutStartThrows() {
        let recorder = Recorder()
        #expect(throws: Recorder.RecorderError.notRecording) {
            try recorder.stop()
        }
    }
}
