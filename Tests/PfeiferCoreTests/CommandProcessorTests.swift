import Foundation
@testable import PfeiferCore
import Testing

/// A `CommandProcessor` with scriptable availability and output, for
/// coordinator tests. Not part of the app target.
final class MockCommandProcessor: CommandProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var _available = true
    private var _result: Result<String, Error> = .success("processed transcript")
    private(set) var inputs: [String] = []

    var available: Bool {
        get { lock.withLock { _available } }
        set { lock.withLock { _available = newValue } }
    }

    var result: Result<String, Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    var isAvailable: Bool {
        get async { lock.withLock { _available } }
    }

    func process(_ transcript: String) async throws -> String {
        try lock.withLock {
            inputs.append(transcript)
            return try _result.get()
        }
    }
}

/// The concrete backend needs Apple Intelligence to run, so its behavior
/// is exercised manually (see docs/roadmap.md Phase 2). These tests only
/// pin the parts that are model-independent: the error vocabulary and the
/// instruction contract the model is handed.
@Suite
struct FoundationModelCommandProcessorTests {
    @Test
    func instructionsDescribeThePostProcessorContract() {
        let text = FoundationModelCommandProcessor.instructions
        #expect(!text.isEmpty)
        #expect(text.localizedCaseInsensitiveContains("post-processor"))
        #expect(text.localizedCaseInsensitiveContains("unchanged"))
    }

    @Test
    func errorCasesAreDistinct() {
        #expect(CommandProcessorError.unavailable != CommandProcessorError.emptyResponse)
        #expect(
            CommandProcessorError.generationFailed("a")
                != CommandProcessorError.generationFailed("b"))
    }
}
