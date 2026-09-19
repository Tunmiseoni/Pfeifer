import AppKit

/// The menu-bar face of Pfeifer: an icon that mirrors the pipeline state
/// and a menu with a status line, a Start/Stop fallback for when the
/// chord can't be used, an Accessibility recheck, and Quit.
///
/// The menu re-checks Accessibility silently every time it opens, so
/// granting trust in System Settings is picked up without restarting the
/// app — the system prompt itself is requested only once, at launch.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    enum Display: Equatable {
        case warming
        case ready
        case requestingMicrophone
        case microphoneDenied
        case accessibilityNeeded
        case recording
        case transcribing
        case processing
        case injecting
        case failed(String)
    }

    private let statusItem: NSStatusItem
    private let onToggle: () -> Void
    private let onRecheckAccessibility: () -> Void
    private let onCopyRawTranscript: () -> Void
    private let onCopyInsertedText: () -> Void
    private let hasRecovery: () -> (raw: Bool, inserted: Bool)
    private let onQuit: () -> Void

    private let statusLine: NSMenuItem
    private let toggleLine: NSMenuItem
    private let copyRawLine: NSMenuItem
    private let copyInsertedLine: NSMenuItem
    private let recheckLine: NSMenuItem
    private let hintLine: NSMenuItem

    var display: Display {
        didSet {
            guard oldValue != display else { return }
            render()
        }
    }

    init(
        initialDisplay: Display,
        onToggle: @escaping () -> Void,
        onRecheckAccessibility: @escaping () -> Void,
        onCopyRawTranscript: @escaping () -> Void,
        onCopyInsertedText: @escaping () -> Void,
        hasRecovery: @escaping () -> (raw: Bool, inserted: Bool),
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.display = initialDisplay
        self.onToggle = onToggle
        self.onRecheckAccessibility = onRecheckAccessibility
        self.onCopyRawTranscript = onCopyRawTranscript
        self.onCopyInsertedText = onCopyInsertedText
        self.hasRecovery = hasRecovery
        self.onQuit = onQuit

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toggleLine = NSMenuItem(title: "", action: #selector(toggleClicked), keyEquivalent: "")
        menu.addItem(toggleLine)

        copyRawLine = NSMenuItem(
            title: "Copy last raw transcript", action: #selector(copyRawClicked),
            keyEquivalent: "")
        menu.addItem(copyRawLine)

        copyInsertedLine = NSMenuItem(
            title: "Copy last inserted text", action: #selector(copyInsertedClicked),
            keyEquivalent: "")
        menu.addItem(copyInsertedLine)

        menu.addItem(.separator())
        recheckLine = NSMenuItem(
            title: "Recheck Accessibility…", action: #selector(recheckClicked),
            keyEquivalent: "")
        menu.addItem(recheckLine)

        // Rebuilds change a dev build's code signature, which silently
        // invalidates an existing grant — the toggle stays on but trust
        // doesn't. Only meaningful in the accessibility-needed state.
        hintLine = NSMenuItem(
            title: "Already listed and on? Remove and re-add after a rebuild",
            action: nil, keyEquivalent: "")
        hintLine.isEnabled = false
        menu.addItem(hintLine)

        menu.addItem(.separator())
        let quitLine = NSMenuItem(
            title: "Quit Pfeifer", action: #selector(quitClicked), keyEquivalent: "q")
        menu.addItem(quitLine)

        super.init()

        toggleLine.target = self
        copyRawLine.target = self
        copyInsertedLine.target = self
        recheckLine.target = self
        quitLine.target = self
        menu.delegate = self
        statusItem.menu = menu
        render()
    }

    // MARK: - NSMenuDelegate (recheck on every menu open)

    func menuWillOpen(_ menu: NSMenu) {
        onRecheckAccessibility()
        refreshRecoveryItems()
    }

    // MARK: - Actions

    @objc private func toggleClicked() {
        onToggle()
    }

    @objc private func copyRawClicked() {
        onCopyRawTranscript()
    }

    @objc private func copyInsertedClicked() {
        onCopyInsertedText()
    }

    @objc private func recheckClicked() {
        onRecheckAccessibility()
    }

    @objc private func quitClicked() {
        onQuit()
    }

    // MARK: - Rendering

    private func render() {
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName, accessibilityDescription: statusText)
        statusItem.button?.toolTip = statusText
        statusLine.title = statusText
        toggleLine.title = isRecording ? "Stop dictation" : "Start dictation"
        recheckLine.isHidden = display != .accessibilityNeeded
        hintLine.isHidden = display != .accessibilityNeeded
        refreshRecoveryItems()
    }

    private func refreshRecoveryItems() {
        let availability = hasRecovery()
        copyRawLine.isEnabled = availability.raw
        copyInsertedLine.isEnabled = availability.inserted
    }

    private var isRecording: Bool {
        switch display {
        case .recording: return true
        default: return false
        }
    }

    private var statusText: String {
        switch display {
        case .warming: return "Pfeifer — warming up…"
        case .ready: return "Pfeifer — ready (Right-⌥+Space)"
        case .requestingMicrophone: return "Pfeifer — check the microphone prompt"
        case .microphoneDenied: return "Pfeifer — microphone access denied"
        case .accessibilityNeeded:
            return "Pfeifer — grant Accessibility in System Settings"
        case .recording: return "Pfeifer — recording…"
        case .transcribing: return "Pfeifer — transcribing…"
        case .processing: return "Pfeifer — applying command…"
        case .injecting: return "Pfeifer — inserting…"
        case .failed(let reason): return "Pfeifer — \(reason)"
        }
    }

    private var symbolName: String {
        switch display {
        case .warming: return "hourglass"
        case .ready: return "mic"
        case .requestingMicrophone, .microphoneDenied: return "mic.slash"
        case .accessibilityNeeded: return "exclamationmark.shield"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .processing: return "wand.and.stars"
        case .injecting: return "arrow.down.doc"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
