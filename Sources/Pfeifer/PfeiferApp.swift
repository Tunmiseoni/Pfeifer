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

    /// The transcriber's settled state, kept current by the warm-up task so
    /// a grant that arrives late doesn't park the menu bar at "warming".
    private var transcriberReadyDisplay: StatusItemController.Display = .warming
    private var accessibilityPollTask: Task<Void, Never>?

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
            self.transcriberReadyDisplay = ready
                ? .ready : .failed("Model failed to load")
            if self.statusItem?.display == .warming {
                self.statusItem?.display = self.transcriberReadyDisplay
            }
        }

        installHotkeyWatcherOrPromptForAccessibility(prompt: true)
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
                self?.installHotkeyWatcherOrPromptForAccessibility(prompt: false)
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }

    /// The Accessibility gate: request the system dialog at most once per
    /// process (launch only — every recheck must poll silently, or the
    /// dialog spams on each menu open), install the watcher when trusted,
    /// and surface the grant-instructions state when not.
    private func installHotkeyWatcherOrPromptForAccessibility(prompt: Bool) {
        // String value of kAXTrustedCheckOptionPrompt — the C global itself
        // is not concurrency-safe to reference under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            statusItem?.display = .accessibilityNeeded
            startAccessibilityPollingIfNeeded()
            return
        }

        stopAccessibilityPolling()

        guard !watcherStarted else {
            settleDisplayAfterWatcherInstall()
            return
        }

        let watcher = HotkeyWatcher { [weak self] in
            self?.toggle()
        }
        do {
            try watcher.start()
            watcherStarted = true
            hotkeyWatcher = watcher
            settleDisplayAfterWatcherInstall()
        } catch {
            // Trusted but the tap still failed (e.g. another utility owns
            // it) — that is not an Accessibility problem, so don't send the
            // user to System Settings for it.
            statusItem?.display = .failed("Hotkey tap unavailable")
        }
    }

    /// While untrusted, poll for the grant so the watcher is installed the
    /// moment trust appears — System Settings grants are otherwise only
    /// noticed on the next menu open or manual recheck.
    private func startAccessibilityPollingIfNeeded() {
        guard accessibilityPollTask == nil else { return }
        accessibilityPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if AXIsProcessTrusted() {
                    self.installHotkeyWatcherOrPromptForAccessibility(prompt: false)
                }
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
    }

    /// Once the watcher is (re)installed, a stale accessibility-needed or
    /// tap-failure state gives way to the transcriber's current state.
    private func settleDisplayAfterWatcherInstall() {
        switch statusItem?.display {
        case .accessibilityNeeded?, .failed("Hotkey tap unavailable")?:
            statusItem?.display = transcriberReadyDisplay
        default:
            break
        }
    }

    // MARK: - Interaction

    private func toggle() {
        guard let coordinator else { return }

        switch microphonePermission {
        case .granted:
            coordinator.toggle()
        case .denied:
            showMicrophoneDenied()
        case .unknown:
            // Settle permission without wasting this tap: an existing
            // grant is read synchronously and records immediately, and a
            // first-ever request chains straight into recording on grant.
            switch Recorder.microphoneStatus() {
            case .granted:
                microphonePermission = .granted
                coordinator.toggle()
            case .denied:
                showMicrophoneDenied()
            case .undetermined:
                statusItem?.display = .requestingMicrophone
                Task { [weak self] in
                    let granted = await Recorder.requestMicrophonePermission()
                    guard let self else { return }
                    self.microphonePermission = granted ? .granted : .denied
                    if granted {
                        self.coordinator?.toggle()
                    } else {
                        self.showMicrophoneDenied()
                    }
                }
            }
        }
    }

    private func showMicrophoneDenied() {
        microphonePermission = .denied
        statusItem?.display = .microphoneDenied
        Task {
            await UserNotifier().notify(
                title: "Pfeifer",
                body: "Microphone access is denied — enable it in System Settings for Pfeifer.")
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
