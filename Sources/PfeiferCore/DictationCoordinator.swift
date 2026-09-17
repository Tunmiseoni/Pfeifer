import AppKit
import Foundation

/// Owns the dictation pipeline state machine:
/// `idle → recording → transcribing → injecting → idle`.
///
/// Every dependency is protocol-injected. A transcript is never silently
/// lost: an empty one is a silent no-op, but anything captured either gets
/// inserted or lands on the clipboard with a notification. A recording that
/// stops while the model is still loading simply waits inside `transcribe`
/// (the status item shows the transcribing state meanwhile).
@MainActor
public final class DictationCoordinator {
    public enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case processing
        case injecting
    }

    public enum CoordinatorEvent: Equatable, Sendable {
        case stateChanged(State)
        /// Something went wrong; the user was notified with this reason.
        case failed(String)
    }

    public typealias EventHandler = @MainActor @Sendable (CoordinatorEvent) -> Void

    public private(set) var state: State = .idle
    public let onEvent: EventHandler

    private let recorder: any AudioRecorder
    private let transcriber: any Transcriber
    private let commandProcessor: any CommandProcessor
    private let injector: any TextInjector
    private let notifier: any Notifier

    /// Whether the in-flight (or about-to-start) utterance goes through
    /// command mode. Latched when recording starts: the stop tap uses the
    /// mode the recording was started with, regardless of how it is tapped.
    private var commandModeActive = false

    public init(
        recorder: any AudioRecorder,
        transcriber: any Transcriber,
        commandProcessor: any CommandProcessor,
        injector: any TextInjector,
        notifier: any Notifier,
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.commandProcessor = commandProcessor
        self.injector = injector
        self.notifier = notifier
        self.onEvent = onEvent
    }

    /// The chord was tapped: start recording when idle, stop-and-process
    /// when recording. Taps during transcribing/processing/injecting are
    /// ignored — the in-flight utterance finishes first.
    ///
    /// - Parameter command: true starts a command-mode utterance whose
    ///   transcript is post-processed before insertion. Only meaningful
    ///   when starting (idle); the stop tap inherits the latched mode.
    public func toggle(command: Bool = false) {
        switch state {
        case .idle:
            commandModeActive = command
            do {
                try recorder.start()
                transition(to: .recording)
            } catch {
                commandModeActive = false
                fail("Couldn't start recording: \(describe(error))")
            }
        case .recording:
            let samples = (try? recorder.stop()) ?? []
            let active = commandModeActive
            commandModeActive = false
            transition(to: .transcribing)
            Task { await process(samples, command: active) }
        case .transcribing, .processing, .injecting:
            break
        }
    }

    private func process(_ samples: [Float], command: Bool) async {
        let text: String
        do {
            text = try await transcriber.transcribe(samples)
        } catch {
            fail("Transcription failed: \(describe(error))")
            transition(to: .idle)
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Silent recording: nothing to insert, nothing to lose.
        guard !trimmed.isEmpty else {
            transition(to: .idle)
            return
        }

        var finalText = trimmed
        if command {
            transition(to: .processing)
            do {
                // Phase B compatibility while the decision table lands in
                // Phase C: command mode currently always cleans up.
                finalText = try await commandProcessor.process(trimmed, transform: .cleanup)
            } catch {
                // The words are still good — insert them verbatim rather
                // than lose the utterance to an LLM failure.
                finalText = trimmed
                await notifier.notify(
                    title: "Pfeifer",
                    body: "Command mode failed — inserted your words verbatim.")
            }
        }

        transition(to: .injecting)
        do {
            let inserted = try await injector.insert(text: finalText)
            if !inserted {
                // The injector already left the transcript on the clipboard.
                await notifier.notify(
                    title: "Pfeifer",
                    body: "Couldn't paste into the frontmost app — the transcript is on your clipboard.")
            }
            transition(to: .idle)
        } catch {
            // Force the never-lost guarantee: put the transcript on the
            // clipboard ourselves, then tell the user where it is.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(finalText, forType: .string)
            await notifier.notify(
                title: "Pfeifer",
                body: "Insertion failed — the transcript is on your clipboard.")
            transition(to: .idle)
        }
    }

    private func transition(to next: State) {
        state = next
        onEvent(.stateChanged(next))
    }

    private func fail(_ reason: String) {
        onEvent(.failed(reason))
        Task {
            await notifier.notify(title: "Pfeifer", body: reason)
        }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }
}
