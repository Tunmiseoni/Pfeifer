import AppKit
import PfeiferCore

@main
struct PfeiferApp {
    static func main() {
        guard meetsPlatformFloor() else {
            presentFloorFailure()
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = delegate  // keep the delegate alive for the run loop
        app.run()
    }

    /// Apple Silicon and macOS 26+ per docs/product.md. Apple Intelligence
    /// is not checked in v1: it only gates Phase 2's command mode.
    private static func meetsPlatformFloor() -> Bool {
        #if arch(arm64)
        let onSupportedArch = true
        #else
        let onSupportedArch = false
        #endif
        return onSupportedArch
            && ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    private static func presentFloorFailure() {
        let alert = NSAlert()
        alert.messageText = "Pfeifer requires macOS 26 or newer on Apple Silicon"
        alert.informativeText =
            "This Mac is below the platform floor (see docs/product.md). Nothing was recorded."
        alert.runModal()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum MicrophonePermission: Equatable {
        case unknown
        case granted
        case denied
    }

    private var statusItem: StatusItemController?
    private var coordinator: DictationCoordinator?
    private var hotkeyWatcher: HotkeyWatcher?
    private var transcriber: (any Transcriber)?

    private var microphonePermission: MicrophonePermission = .unknown
    private var watcherStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Model directory first: without it the app has nothing to say.
        let modelDirectory: URL
        do {
            modelDirectory = try ModelLocator.resolve()
        } catch {
            installStatusItem(display: .failed("Model not found — see docs"))
            return
        }

        let transcriber = FluidAudioTranscriber.start(modelDirectory: modelDirectory)
        self.transcriber = transcriber

        let coordinator = DictationCoordinator(
            recorder: Recorder(),
            transcriber: transcriber,
            injector: ClipboardInjector(),
            notifier: UserNotifier(),
            onEvent: { [weak self] event in
                self?.handle(event)
            }
        )
        self.coordinator = coordinator

        installStatusItem(display: .warming)

        // Warm-up indicator: settle once loading completes.
        Task { [weak self] in
            let ready = await transcriber.isReady
            guard let self else { return }
            if ready {
                if self.statusItem?.display == .warming {
                    self.statusItem?.display = .ready
                }
            } else if self.statusItem?.display == .warming {
                self.statusItem?.display = .failed("Model failed to load")
            }
        }

        installHotkeyWatcherOrPromptForAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyWatcher?.stop()
    }

    // MARK: - Wiring

    private func installStatusItem(display: StatusItemController.Display) {
        guard statusItem == nil else {
            statusItem?.display = display
            return
        }
        statusItem = StatusItemController(
            initialDisplay: display,
            onToggle: { [weak self] in self?.toggle() },
            onRecheckAccessibility: { [weak self] in
                self?.installHotkeyWatcherOrPromptForAccessibility()
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }

    /// The Accessibility gate: prompt once via the system dialog, install
    /// the watcher when trusted, and surface the grant-instructions state
    /// when not.
    private func installHotkeyWatcherOrPromptForAccessibility() {
        // String value of kAXTrustedCheckOptionPrompt — the C global itself
        // is not concurrency-safe to reference under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            statusItem?.display = .accessibilityNeeded
            return
        }

        guard !watcherStarted else {
            if statusItem?.display == .accessibilityNeeded {
                statusItem?.display = transcriberReadyDisplay()
            }
            return
        }

        let watcher = HotkeyWatcher { [weak self] in
            self?.toggle()
        }
        do {
            try watcher.start()
            watcherStarted = true
            hotkeyWatcher = watcher
            if statusItem?.display == .accessibilityNeeded {
                statusItem?.display = transcriberReadyDisplay()
            }
        } catch {
            statusItem?.display = .accessibilityNeeded
        }
    }

    private func transcriberReadyDisplay() -> StatusItemController.Display {
        // The warm-up task corrects this to .ready/.failed on its own.
        .warming
    }

    // MARK: - Interaction

    private func toggle() {
        guard let coordinator else { return }

        switch microphonePermission {
        case .granted:
            coordinator.toggle()
        case .denied:
            statusItem?.display = .microphoneDenied
            Task {
                await UserNotifier().notify(
                    title: "Pfeifer",
                    body: "Microphone access is denied — enable it in System Settings for Pfeifer.")
            }
        case .unknown:
            // This first tap only asks for permission; the next one records.
            statusItem?.display = .requestingMicrophone
            Task { [weak self] in
                let granted = await Recorder.requestMicrophonePermission()
                guard let self else { return }
                self.microphonePermission = granted ? .granted : .denied
                self.statusItem?.display = granted
                    ? .ready : .microphoneDenied
            }
        }
    }

    private func handle(_ event: DictationCoordinator.CoordinatorEvent) {
        switch event {
        case .stateChanged(let state):
            switch state {
            case .idle: statusItem?.display = .ready
            case .recording: statusItem?.display = .recording
            case .transcribing: statusItem?.display = .transcribing
            case .injecting: statusItem?.display = .injecting
            }
        case .failed(let reason):
            statusItem?.display = .failed(reason)
            // Failure states clear back to ready on the next interaction.
        }
    }
}
