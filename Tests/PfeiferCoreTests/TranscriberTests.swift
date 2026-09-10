import Foundation
@testable import PfeiferCore
import Testing

/// A `Transcriber` with scriptable behavior, for coordinator tests now and
/// app tests later. Not part of the app target.
final class MockTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _ready = false
    private var _cannedResult: Result<String, Error> = .success("mock transcript")
    private(set) var transcribeCallCount = 0
    private(set) var lastSamples: [Float]?

    var cannedResult: Result<String, Error> {
        get { lock.withLock { _cannedResult } }
        set { lock.withLock { _cannedResult = newValue } }
    }

    var isReady: Bool {
        get async { lock.withLock { _ready } }
    }

    func markReady() {
        lock.withLock { _ready = true }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try lock.withLock {
            transcribeCallCount += 1
            lastSamples = samples
            return try _cannedResult.get()
        }
    }
}

@Suite
struct TranscriberProtocolTests {
    @Test
    func mockReportsReadinessAndTranscribes() async throws {
        let mock = MockTranscriber()
        #expect(await mock.isReady == false)

        mock.markReady()
        #expect(await mock.isReady == true)

        let text = try await mock.transcribe([0, 0.5, -0.5])
        #expect(text == "mock transcript")
        #expect(mock.transcribeCallCount == 1)
        #expect(mock.lastSamples == [0, 0.5, -0.5])
    }

    @Test
    func errorPropagatesThroughTranscribe() async throws {
        struct Boom: Error, Equatable {}
        let mock = MockTranscriber()
        mock.cannedResult = .failure(Boom())

        await #expect(throws: Boom.self) {
            _ = try await mock.transcribe([0])
        }
    }
}

@Suite
struct FluidAudioTranscriberPreflightTests {
    @Test
    func missingModelDirectorySurfacesClearError() async throws {
        let nowhere = URL(
            fileURLWithPath: "/nonexistent-pfeifer-model-dir", isDirectory: true)
        let transcriber = FluidAudioTranscriber.start(modelDirectory: nowhere)

        await #expect(throws: TranscriberError.self) {
            _ = try await transcriber.transcribe([0, 0, 0])
        }
        #expect(await transcriber.isReady == false)
    }

    @Test
    func preflightListsEveryMissingFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfeifer-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let transcriber = FluidAudioTranscriber.start(modelDirectory: tempDir)

        do {
            _ = try await transcriber.transcribe([0])
            Issue.record("expected modelMissing")
        } catch let TranscriberError.modelMissing(directory: _, missingFiles: files) {
            #expect(files.count == 4)
            #expect(files.contains("parakeet_unified_encoder_int8.mlmodelc"))
            #expect(files.contains("vocab.json"))
        }
    }
}
