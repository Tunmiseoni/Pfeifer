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
        injector: MockInjector = MockInjector(),
        recorder: MockRecorder = MockRecorder(),
        notifier: MockNotifier = MockNotifier()
    ) -> (DictationCoordinator, MockTranscriber, MockInjector, MockRecorder, MockNotifier) {
        let events = EventLog()
        let coordinator = DictationCoordinator(
            recorder: recorder,
            transcriber: transcriber,
            injector: injector,
            notifier: notifier,
            onEvent: { events.record($0) }
        )
        return (coordinator, transcriber, injector, recorder, notifier)
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
        let (coordinator, transcriber, injector, recorder, notifier) = makePipeline()
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
        let (coordinator, transcriber, injector, _, notifier) = makePipeline()
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
        let (coordinator, transcriber, injector, _, notifier) = makePipeline()
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
        let (coordinator, transcriber, injector, _, notifier) = makePipeline()
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
        let (coordinator, _, _, recorder, notifier) = makePipeline()
        recorder.startError = Boom()

        coordinator.toggle()
        await settle()

        #expect(coordinator.state == .idle)
        #expect(notifier.notices.count == 1)
    }

    @Test
    func toggleDuringProcessingIsIgnored() async throws {
        let (coordinator, transcriber, injector, recorder, _) = makePipeline()
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
}
