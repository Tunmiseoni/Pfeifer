import AppKit
@testable import PfeiferCore
import Testing

// MARK: - Mocks

final class MockRecorder: AudioRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var _running = false
    var startError: Error?
    var cannedSamples: [Float] = [0.1, 0.2, 0.3]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws {
        try lock.withLock {
            if let startError { throw startError }
            startCount += 1
            _running = true
        }
    }

    func stop() throws -> [Float] {
        try lock.withLock {
            guard _running else { throw Recorder.RecorderError.notRecording }
            _running = false
            stopCount += 1
            return cannedSamples
        }
    }
}

final class MockInjector: TextInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<Bool, Error> = .success(true)
    private(set) var insertions: [String] = []

    var result: Result<Bool, Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    func insert(text: String) async throws -> Bool {
        try lock.withLock {
            insertions.append(text)
            return try _result.get()
        }
    }
}

final class MockNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var notices: [(title: String, body: String)] = []

    func notify(title: String, body: String) async {
        lock.withLock {
            notices.append((title, body))
        }
    }
}

// MARK: - Coordinator state machine

@MainActor
@Suite
struct DictationCoordinatorTests {
    private func makePipeline(
        transcriber: MockTranscriber = MockTranscriber(),
        commandProcessor: MockCommandProcessor = MockCommandProcessor(),
        injector: MockInjector = MockInjector(),
        recorder: MockRecorder = MockRecorder(),
        notifier: MockNotifier = MockNotifier(),
        spokenPunctuationEnabled: Bool = true
    ) -> (
        DictationCoordinator, MockTranscriber, MockCommandProcessor, MockInjector, MockRecorder,
        MockNotifier
    ) {
        let events = EventLog()
        let coordinator = DictationCoordinator(
            recorder: recorder,
            transcriber: transcriber,
            commandProcessor: commandProcessor,
            injector: injector,
            notifier: notifier,
            spokenPunctuationEnabled: { spokenPunctuationEnabled },
            onEvent: { events.record($0) }
        )
        return (coordinator, transcriber, commandProcessor, injector, recorder, notifier)
    }

    /// Collects coordinator events across await points.
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DictationCoordinator.CoordinatorEvent] = []

        func record(_ event: DictationCoordinator.CoordinatorEvent) {
            lock.withLock { events.append(event) }
        }

        var states: [DictationCoordinator.State] {
            lock.withLock {
                events.compactMap {
                    if case .stateChanged(let state) = $0 { return state }
                    return nil
                }
            }
        }

        var failures: [String] {
            lock.withLock {
                events.compactMap {
                    if case .failed(let reason) = $0 { return reason }
                    return nil
                }
            }
        }
    }

    /// Drive the coordinator's async processing to completion.
    private func settle() async {
        // The process task is created with Task { }; give it and the
        // notifier's task a chance to run to completion.
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        await Task.yield()
    }

    @Test
    func happyPathIdleThroughInjectingBackToIdle() async throws {
        let (coordinator, transcriber, _, injector, recorder, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("hello world")

        #expect(coordinator.state == .idle)
        coordinator.toggle()
        #expect(coordinator.state == .recording)
        coordinator.toggle()
        #expect(coordinator.state == .transcribing)

        await settle()

        #expect(coordinator.state == .idle)
        #expect(recorder.startCount == 1)
        #expect(recorder.stopCount == 1)
        #expect(injector.insertions == ["hello world"])
        #expect(notifier.notices.isEmpty)
    }

    @Test
    func emptyTranscriptIsASilentNoOp() async throws {
        let (coordinator, transcriber, _, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("   \n  ")

        coordinator.toggle()
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(injector.insertions.isEmpty)
        #expect(notifier.notices.isEmpty)
    }

    @Test
    func transcriptionFailureNotifiesAndReturnsToIdle() async throws {
        struct Boom: Error {}
        let (coordinator, transcriber, _, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .failure(Boom())

        coordinator.toggle()
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(injector.insertions.isEmpty)
        #expect(notifier.notices.count == 1)
    }

    @Test
    func injectionRefusalNotifiesClipboardFallback() async throws {
        let (coordinator, transcriber, _, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("the transcript")
        injector.result = .success(false)  // poster failed; text on clipboard

        coordinator.toggle()
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(injector.insertions == ["the transcript"])
        #expect(notifier.notices.count == 1)
        #expect(notifier.notices.first?.body.contains("clipboard") == true)
    }

    @Test
    func recorderStartFailureFailsWithoutRecording() async {
        struct Boom: Error {}
        let (coordinator, _, _, _, recorder, notifier) = makePipeline()
        recorder.startError = Boom()

        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(notifier.notices.count == 1)
    }

    @Test
    func toggleDuringProcessingIsIgnored() async throws {
        let (coordinator, transcriber, _, injector, recorder, _) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("first utterance")

        coordinator.toggle()
        coordinator.toggle()
        #expect(coordinator.state == .transcribing)

        // Tap-tap-tap while transcribing: no second recording may start.
        coordinator.toggle()
        coordinator.toggle()
        #expect(coordinator.state == .transcribing)
        #expect(recorder.startCount == 1)

        await settle()

        #expect(coordinator.state == .idle)
        #expect(injector.insertions == ["first utterance"])

        // After settling, a new recording can begin.
        coordinator.toggle()
        #expect(coordinator.state == .recording)
        _ = try recorder.stop()
    }

    // MARK: - Command mode: cleanup path

    @Test
    func commandModeWithNoTriggerRunsCleanup() async throws {
        let (coordinator, transcriber, processor, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("apples bananas cherries")
        processor.result = .success("Apples, bananas, cherries.")

        coordinator.toggle(command: true)
        #expect(coordinator.state == .recording)
        coordinator.toggle()
        #expect(coordinator.state == .transcribing)

        await settle()

        #expect(coordinator.state == .idle)
        #expect(processor.transforms == [.cleanup])
        #expect(processor.inputs == ["apples bananas cherries"])
        #expect(injector.insertions == ["Apples, bananas, cherries."])
        #expect(notifier.notices.isEmpty)
    }

    @Test
    func cleanupFailureInsertsDeterministicCleanup() async throws {
        struct Boom: Error {}
        let (coordinator, transcriber, processor, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("I I went to the shop")
        processor.result = .failure(Boom())

        coordinator.toggle(command: true)
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        // Deterministic cleanup removes the repetition; model failure must
        // never lose the utterance.
        #expect(injector.insertions == ["I went to the shop"])
        #expect(notifier.notices.count == 1)
        #expect(notifier.notices.first?.body.contains("verbatim") == true)
    }

    @Test
    func guardRejectsFabricatedOutputAndKeepsTheUsersWords() async throws {
        // The originally-reported failure: a command-shaped utterance was
        // executed by the model, which returned a fabricated document.
        let (coordinator, transcriber, processor, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        let utterance =
            "make these changes to agents.md, add an agent named Agent X and update the docs"
        transcriber.cannedResult = .success(utterance)
        processor.result = .success(
            """
            # Mini Agent.md

            - Added an agent named Agent X
            - Updated the docs
            """)

        coordinator.toggle(command: true)
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(processor.transforms == [.cleanup])
        // The guard rejects the fabrication and the user's actual words go
        // in instead.
        #expect(injector.insertions == [utterance])
        #expect(notifier.notices.count == 1)
        #expect(notifier.notices.first?.body.contains("wrong") == true)
    }

    // MARK: - Command mode: transform path

    @Test
    func transformUsesTheRemainderAsContent() async throws {
        let (coordinator, transcriber, processor, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("make this a bullet list apples bananas")
        processor.result = .success("• apples\n• bananas")

        coordinator.toggle(command: true)
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(processor.calls.count == 1)
        #expect(processor.calls.first?.transform == .bullets)
        #expect(processor.calls.first?.content == "apples bananas")
        #expect(injector.insertions == ["• apples\n• bananas"])
        #expect(notifier.notices.isEmpty)
    }

    @Test
    func transformFailureInsertsContentVerbatim() async throws {
        struct Boom: Error {}
        let (coordinator, transcriber, processor, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("make this a bullet list apples bananas")
        processor.result = .failure(Boom())

        coordinator.toggle(command: true)
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(injector.insertions == ["apples bananas"])
        #expect(notifier.notices.count == 1)
        #expect(notifier.notices.first?.body.contains("verbatim") == true)
    }

    @Test
    func requiresSelectionTransformRefusesLoudly() async throws {
        let (coordinator, transcriber, processor, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("summarize this")

        coordinator.toggle(command: true)
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(processor.calls.isEmpty)
        #expect(injector.insertions.isEmpty)
        #expect(notifier.notices.count == 1)
        #expect(notifier.notices.first?.body.contains("selected text") == true)
    }

    @Test
    func emptyRemainderRefusesLoudly() async throws {
        let (coordinator, transcriber, processor, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("make this more concise")

        coordinator.toggle(command: true)
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(processor.calls.isEmpty)
        #expect(injector.insertions.isEmpty)
        #expect(notifier.notices.count == 1)
    }

    // MARK: - Command mode: shared behavior

    @Test
    func commandModeRetainsRawAndInsertedText() async throws {
        let (coordinator, transcriber, processor, injector, _, _) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("make this a bullet list a b")
        processor.result = .success("• a\n• b")

        coordinator.toggle(command: true)
        coordinator.toggle()
        await settle()

        #expect(coordinator.lastRawTranscript == "make this a bullet list a b")
        #expect(coordinator.lastInsertedText == "• a\n• b")
        #expect(injector.insertions == ["• a\n• b"])
    }

    @Test
    func plainDictationNeverInvokesTheProcessor() async throws {
        let (coordinator, transcriber, processor, injector, _, _) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("verbatim words")

        coordinator.toggle()
        coordinator.toggle()
        await settle()

        #expect(processor.calls.isEmpty)
        #expect(injector.insertions == ["verbatim words"])
    }

    @Test
    func stopTapInheritsTheLatchedMode() async throws {
        // Starting with the command chord and stopping with a plain tap
        // must still run command mode — the mode belongs to the recording.
        let (coordinator, transcriber, processor, injector, _, _) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("raw words")
        processor.result = .success("raw")  // a valid cleanup subsequence

        coordinator.toggle(command: true)
        coordinator.toggle()  // stop, no command flag
        await settle()

        #expect(processor.transforms == [.cleanup])
        #expect(processor.inputs == ["raw words"])
        #expect(injector.insertions == ["raw"])
    }

    @Test
    func commandModeWithEmptyTranscriptStaysANoOp() async throws {
        let (coordinator, transcriber, processor, injector, _, notifier) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("   ")

        coordinator.toggle(command: true)
        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(processor.calls.isEmpty)
        #expect(injector.insertions.isEmpty)
        #expect(notifier.notices.isEmpty)
    }

    // MARK: - Spoken punctuation

    @Test
    func plainDictationAppliesSpokenPunctuation() async throws {
        let (coordinator, transcriber, _, injector, _, _) = makePipeline()
        transcriber.markReady()
        transcriber.cannedResult = .success("quote hello world unquote")

        coordinator.toggle()
        coordinator.toggle()
        await settle()

        #expect(injector.insertions == ["\"hello world\""])
        #expect(coordinator.lastRawTranscript == "\"hello world\"")
    }

    @Test
    func spokenPunctuationCanBeDisabled() async throws {
        let (coordinator, transcriber, _, injector, _, _) = makePipeline(
            spokenPunctuationEnabled: false)
        transcriber.markReady()
        transcriber.cannedResult = .success("quote hello world unquote")

        coordinator.toggle()
        coordinator.toggle()
        await settle()

        #expect(injector.insertions == ["quote hello world unquote"])
    }
}
