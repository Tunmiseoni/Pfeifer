import Foundation
@testable import PfeiferCore
import Testing

/// A `CommandProcessor` with scriptable availability and output, for
/// coordinator tests. Not part of the app target.
final class MockCommandProcessor: CommandProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var _available = true
    private var _result: Result<String, Error> = .success("processed transcript")
    private(set) var calls: [(content: String, transform: Transform)] = []

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

    /// The content of each call, for tests that don't care about the transform.
    var inputs: [String] {
        lock.withLock { calls.map(\.content) }
    }

    /// The transform of each call.
    var transforms: [Transform] {
        lock.withLock { calls.map(\.transform) }
    }

    func process(_ content: String, transform: Transform) async throws -> String {
        try lock.withLock {
            calls.append((content, transform))
            return try _result.get()
        }
    }
}

/// The concrete backend needs Apple Intelligence to run, so its behavior
/// is exercised manually (see docs/roadmap.md Phase 2). These tests only
/// pin the parts that are model-independent: the error vocabulary and the
/// per-transform instruction contract the model is handed.
@Suite
struct FoundationModelCommandProcessorTests {
    @Test
    func everyTransformHasNonEmptyNarrowInstructions() {
        for transform in Transform.allCases {
            let text = CommandTemplates.instruction(for: transform)
            #expect(!text.isEmpty, "\(transform) has no instruction")
            #expect(
                text.localizedCaseInsensitiveContains("Output only"),
                "\(transform) instruction must constrain the output")
        }
    }

    @Test
    func cleanupInstructionCoversFalseStartsAndPreservesFacts() {
        let text = CommandTemplates.instruction(for: .cleanup)
        #expect(text.localizedCaseInsensitiveContains("false start"))
        #expect(text.localizedCaseInsensitiveContains("fact"))
    }

    @Test
    func requiresSelectionIsTrueOnlyForContentlessTransforms() {
        #expect(Transform.summarize.requiresSelection)
        #expect(Transform.rewrite.requiresSelection)
        #expect(Transform.fix.requiresSelection)
        #expect(Transform.bullets.requiresSelection == false)
        #expect(Transform.cleanup.requiresSelection == false)
    }

    @Test
    func errorCasesAreDistinct() {
        #expect(CommandProcessorError.unavailable != CommandProcessorError.emptyResponse)
        #expect(
            CommandProcessorError.generationFailed("a")
                != CommandProcessorError.generationFailed("b"))
    }
}

/// The deterministic safety net for model framing. Shapes and expectations
/// come from docs/command-mode-experiment.md.
@Suite
struct AcknowledgementStripperTests {
    private func strip(_ input: String) -> String {
        FoundationModelCommandProcessor.stripAcknowledgementPrefix(input)
    }

    @Test
    func removesTheObservedPreamble() {
        let observed = """
            Sure, here is the text with the instruction applied:

            Instead of starting for now, just put it in a document. We're going to work on something else before this session is over.
            """
        #expect(
            strip(observed)
                == "Instead of starting for now, just put it in a document. We're going to work on something else before this session is over.")
    }

    @Test
    func removesShorterFramingVariants() {
        #expect(strip("Sure, here is the text:\n\nHello world.") == "Hello world.")
        #expect(strip("Here is the reformatted text: hello world") == "hello world")
        #expect(strip("Certainly, here's the result: ok") == "ok")
    }

    @Test
    func leavesOrdinarySentencesUntouched() {
        // Legitimate openers that are not model framing. If any of these
        // change, the stripper has become too aggressive.
        for sentence in [
            "Sure, I'll take a look at that later today.",
            "Of course we can reschedule the meeting.",
            "Here's the thing about the deployment.",
            "Okay, so the plan is to ship on Friday.",
            "I'll send you the document tomorrow.",
            "The quick brown fox jumps over the lazy dog.",
        ] {
            #expect(strip(sentence) == sentence)
        }
    }

    @Test
    func keepsOriginalWhenStrippingWouldLeaveNothing() {
        let framingOnly = "Sure, here is the text:"
        #expect(strip(framingOnly) == framingOnly)
    }

    @Test
    func trimsSurroundingWhitespace() {
        #expect(strip("  \n hello world \n ") == "hello world")
    }
}
