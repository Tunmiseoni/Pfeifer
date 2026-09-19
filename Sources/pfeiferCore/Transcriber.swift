import FluidAudio
import Foundation

/// Speech-to-text backend. Implementations must be safe to call from any
/// actor; `transcribe` waits for background model loading to finish so a
/// recording that stops during warmup is handled, never dropped.
public protocol Transcriber: Sendable {
    /// True once the backend is loaded and `transcribe` will not wait.
    var isReady: Bool { get async }

    /// Transcribe 16 kHz mono samples to text.
    /// - Throws: `TranscriberError` on a missing model, failed load, or
    ///   backend failure.
    func transcribe(_ samples: [Float]) async throws -> String
}

public enum TranscriberError: Error, Equatable, Sendable {
    /// The model directory is missing one or more required files.
    case modelMissing(directory: String, missingFiles: [String])
    /// Transcribe was called before loading began (or after a load that
    /// produced no manager without recording an error — a programming bug).
    case notLoaded
    /// The backend threw while transcribing.
    case transcriptionFailed(String)
}

/// Parakeet Unified EN 0.6B (int8) behind `Transcriber`, via FluidAudio.
///
/// Loading the CoreML/E5RT models is a background task started at init
/// (~30 s on the first-ever launch while the ANE compile runs, < 0.5 s
/// afterwards — the compile cache persists across launches). `transcribe`
/// awaits that task, so an early recording just takes as long as the
/// remaining warmup. All FluidAudio loads are local-directory only.
public actor FluidAudioTranscriber: Transcriber {
    /// Files `UnifiedAsrManager.loadModels(from:)` reads. The 320 ms
    /// streaming encoder (Phase 3) is deliberately not loaded in v1.
    private static let requiredFiles = [
        "parakeet_unified_encoder_int8.mlmodelc",
        "parakeet_unified_decoder.mlmodelc",
        "parakeet_unified_joint_decision_single_step.mlmodelc",
        "vocab.json",
    ]

    private let modelDirectory: URL
    private var manager: UnifiedAsrManager?
    private var loadTask: Task<Void, Never>?
    private var loadFailure: Error?

    /// Create a transcriber and begin loading the model in the background.
    ///
    /// A factory rather than an eager init because the load task cannot
    /// capture `self` inside a nonisolated actor initializer (Swift 6).
    public static func start(modelDirectory: URL) -> FluidAudioTranscriber {
        let transcriber = FluidAudioTranscriber(modelDirectory: modelDirectory)
        Task { await transcriber.beginLoading() }
        return transcriber
    }

    private init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
        // Refuse any network fetch on FluidAudio's part, process-wide.
        ModelHub.offlineMode = true
    }

    /// Begin the background model load. Idempotent.
    public func beginLoading() {
        guard loadTask == nil, manager == nil else { return }
        loadTask = Task { await self.load() }
    }

    public var isReady: Bool {
        get async {
            await loadTask?.value
            return manager != nil
        }
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        // Defensive: if loading never began (or a start() race), begin now.
        if loadTask == nil && manager == nil {
            beginLoading()
        }
        await loadTask?.value
        if let loadFailure {
            throw loadFailure
        }
        guard let manager else {
            throw TranscriberError.notLoaded
        }
        do {
            return try await manager.transcribe(samples)
        } catch {
            throw TranscriberError.transcriptionFailed(String(describing: error))
        }
    }

    /// Validate the model directory, then load. Failures are stored and
    /// replayed to every caller; a partial load never silently succeeds.
    private func load() async {
        do {
            let missing = Self.requiredFiles.filter {
                !FileManager.default.fileExists(
                    atPath: modelDirectory.appendingPathComponent($0).path)
            }
            guard missing.isEmpty else {
                throw TranscriberError.modelMissing(
                    directory: modelDirectory.path, missingFiles: missing)
            }

            let manager = UnifiedAsrManager()
            try await manager.loadModels(from: modelDirectory)
            self.manager = manager
        } catch {
            loadFailure = error
        }
    }
}
