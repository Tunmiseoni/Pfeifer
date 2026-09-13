@preconcurrency import AVFoundation

/// The recording dependency of `DictationCoordinator`, so the state machine
/// can be unit-tested with a mock microphone.
public protocol AudioRecorder: Sendable {
    func start() throws
    func stop() throws -> [Float]
}

/// Records microphone audio to a 16 kHz mono `[Float]` buffer.
///
/// Not an actor: the input tap fires on an AVAudioEngine thread ("may be
/// invoked on a thread other than the main thread" per the SDK), so state is
/// guarded by `stateLock` and the sample buffer by `accumulationLock`.
/// Conversion runs synchronously inside the tap (48 kHz→16 kHz on 4096-frame
/// buffers is sub-millisecond work). `start`/`stop` are called by the
/// (MainActor) coordinator; the class is safe from any single logical owner.
public final class Recorder: @unchecked Sendable {
    public enum RecorderError: Error, Equatable {
        case alreadyRecording
        case notRecording
        case conversionUnavailable
        case engineStartFailed(String)
    }

    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private var recording = false

    private let accumulationLock = NSLock()
    private var accumulated: [Float] = []

    /// Parakeet's expected input: 16 kHz mono Float32.
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    public init() {}

    public var isRecording: Bool {
        stateLock.withLock { recording }
    }

    /// Samples captured so far without stopping.
    public var currentSamples: [Float] {
        accumulationLock.withLock { accumulated }
    }

    /// Snapshot of the microphone TCC state, queryable without prompting.
    public enum MicrophoneStatus: Sendable, Equatable {
        case granted
        case denied
        case undetermined
    }

    /// The current mic permission — synchronous, and never prompts.
    public static func microphoneStatus() -> MicrophoneStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Request mic permission (TCC). Call before the first recording; a
    /// denial is a manual gate — surfaced, never retried in a loop.
    public static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Begin capturing; audio accumulates until `stop()`.
    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !recording else { throw RecorderError.alreadyRecording }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            throw RecorderError.conversionUnavailable
        }

        accumulationLock.withLock { accumulated.removeAll(keepingCapacity: true) }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = Self.convert(buffer: buffer, with: converter)
            guard !samples.isEmpty else { return }
            self.accumulationLock.lock()
            self.accumulated.append(contentsOf: samples)
            self.accumulationLock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        recording = true
    }

    /// Stop capturing and return everything recorded since `start()`.
    /// Drains in-flight conversions so the tail of the recording is not lost.
    public func stop() throws -> [Float] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard recording else { throw RecorderError.notRecording }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recording = false

        return accumulationLock.withLock {
            let samples = accumulated
            accumulated.removeAll(keepingCapacity: true)
            return samples
        }
    }

    // MARK: - Conversion (pure, unit-tested)

    /// One-shot gate for the converter's input block (which is @Sendable).
    private final class OnceFeeder: @unchecked Sendable {
        private let lock = NSLock()
        private var fed = false
        func alreadyFed() -> Bool {
            lock.withLock {
                defer { fed = true }
                return fed
            }
        }
    }

    /// Convert one input buffer to 16 kHz mono `[Float]` samples.
    static func convert(buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let inputFrames = Double(buffer.frameLength)
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up) + 16)
        guard
            capacity > 0,
            let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: capacity
            )
        else { return [] }

        let feeder = OnceFeeder()
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError,
            withInputFrom: { _, inputStatus in
                if feeder.alreadyFed() {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
        )

        guard status != .error, output.frameLength > 0,
            let channel = output.floatChannelData
        else { return [] }

        return [Float](
            UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength))
        )
    }
}

extension Recorder: AudioRecorder {}
