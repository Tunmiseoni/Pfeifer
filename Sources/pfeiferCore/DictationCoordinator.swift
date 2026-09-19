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
    private let spokenPunctuationEnabled: @MainActor @Sendable () -> Bool

    /// Whether the in-flight (or about-to-start) utterance goes through
    /// command mode. Latched when recording starts: the stop tap uses the
    /// mode the recording was started with, regardless of how it is tapped.
    private var commandModeActive = false

    /// The last raw (post-substitution) transcript and the last text actually
    /// inserted. Retained in memory so the app can offer them for recovery
    /// when a transform paraphrases — see docs/design-command-mode.md §8.
    public private(set) var lastRawTranscript: String?
    public private(set) var lastInsertedText: String?

    public init(
        recorder: any AudioRecorder,
        transcriber: any Transcriber,
        commandProcessor: any CommandProcessor,
        injector: any TextInjector,
        notifier: any Notifier,
        spokenPunctuationEnabled: @escaping @MainActor @Sendable () -> Bool = {
            Preferences.spokenPunctuationEnabled()
        },
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.commandProcessor = commandProcessor
        self.injector = injector
        self.notifier = notifier
        self.spokenPunctuationEnabled = spokenPunctuationEnabled
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

        let substituted = spokenPunctuationEnabled()
            ? SpeechTokens.substitute(text) : text
        let trimmed = substituted.trimmingCharacters(in: .whitespacesAndNewlines)
        // Silent recording: nothing to insert, nothing to lose.
        guard !trimmed.isEmpty else {
            transition(to: .idle)
            return
        }

        lastRawTranscript = trimmed

        if command {
            await processCommand(trimmed)
        } else {
            await insert(trimmed)
        }
    }

    /// Resolve the instruction/content boundary in our code, never in the
    /// model: a leading trigger selects a transform, otherwise the utterance
    /// gets a cleanup pass. Selection-aware branches arrive in Phase D.
    private func processCommand(_ utterance: String) async {
        transition(to: .processing)
        let match = CommandGrammar.match(utterance)

        guard let transform = match.transform else {
            await runCleanup(utterance)
            return
        }
        guard !transform.requiresSelection else {
            await refuse(
                "Command mode needs selected text for that — select the text and try again.")
            return
        }
        guard !match.remainder.isEmpty else {
            await refuse(
                "Command mode couldn't find text to transform — say the text or select it.")
            return
        }
        await runTransform(match.remainder, transform: transform)
    }

    /// Cleanup path: deterministic cleanup first, the model for self-
    /// corrections, then the subsequence guard. Any failure falls back to the
    /// deterministic result, so the user's words are never replaced by a
    /// fabrication.
    private func runCleanup(_ input: String) async {
        let deterministic = DeterministicCleanup.cleanup(input)
        guard !deterministic.isEmpty else {
            // The utterance was nothing but fillers.
            transition(to: .idle)
            return
        }

        do {
            let output = try await commandProcessor.process(deterministic, transform: .cleanup)
            guard SubsequenceGuard.isSubsequence(output, of: input) else {
                await notifier.notify(
                    title: "Pfeifer",
                    body: "Cleanup looked wrong — inserted your words as spoken.")
                await insert(deterministic)
                return
            }
            await insert(output)
        } catch {
            // The words are still good — insert the cleaned transcript rather
            // than lose the utterance to an LLM failure.
            await notifier.notify(
                title: "Pfeifer",
                body: "Command mode failed — inserted your words verbatim.")
            await insert(deterministic)
        }
    }

    /// Transform path: paraphrase is the point, so no subsequence guard. On
    /// failure the pre-transform content is inserted verbatim.
    private func runTransform(_ content: String, transform: Transform) async {
        do {
            let output = try await commandProcessor.process(content, transform: transform)
            await insert(output)
        } catch {
            await notifier.notify(
                title: "Pfeifer",
                body: "Command mode failed — inserted your words verbatim.")
            await insert(content)
        }
    }

    private func refuse(_ reason: String) async {
        await notifier.notify(title: "Pfeifer", body: reason)
        transition(to: .idle)
    }

    private func insert(_ text: String) async {
        transition(to: .injecting)
        do {
            let inserted = try await injector.insert(text: text)
            if !inserted {
                // The injector already left the transcript on the clipboard.
                await notifier.notify(
                    title: "Pfeifer",
                    body: "Couldn't paste into the frontmost app — the transcript is on your clipboard.")
            }
            lastInsertedText = text
            transition(to: .idle)
        } catch {
            // Force the never-lost guarantee: put the transcript on the
            // clipboard ourselves, then tell the user where it is.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            await notifier.notify(
                title: "Pfeifer",
                body: "Insertion failed — the transcript is on your clipboard.")
            lastInsertedText = text
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
