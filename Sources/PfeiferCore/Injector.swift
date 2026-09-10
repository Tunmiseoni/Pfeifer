import AppKit
import CoreGraphics
import Foundation

/// Inserts text at the cursor of the frontmost app.
public protocol TextInjector: Sendable {
    /// - Returns: true when the paste keystroke was posted and the previous
    ///   pasteboard restored. False (or a throw) means the transcript has
    ///   been left on the clipboard for the caller to surface via
    ///   notification — never silently lost.
    func insert(text: String) async throws -> Bool
}

public enum InjectorError: Error, Equatable, Sendable {
    /// Accessibility trust is missing, so synthetic keystrokes are dropped
    /// by the system. The transcript is already on the clipboard.
    case accessibilityNotTrusted
    /// The synthetic ⌘V events could not be built or posted.
    case eventPostFailed
}

/// The v1 injector: save the pasteboard → write the transcript → post a
/// synthetic ⌘V → restore the saved contents after a short delay.
///
/// The delay is the accepted heuristic (~200 ms) for the target app to read
/// the pasteboard; restoring too early truncates the paste, too late leaves
/// the user's clipboard holding the transcript. The keystroke poster is
/// injectable so tests can run without Accessibility trust or real events.
public struct ClipboardInjector: TextInjector {
    /// Posts the synthetic ⌘V into the HID event stream.
    public typealias PastePoster = @Sendable () throws -> Void

    private let restoreDelay: Duration
    private let postPaste: PastePoster

    public init(
        restoreDelay: Duration = .milliseconds(200),
        postPaste: @escaping PastePoster = Self.postSyntheticPaste
    ) {
        self.restoreDelay = restoreDelay
        self.postPaste = postPaste
    }

    public func insert(text: String) async throws -> Bool {
        let backup = PasteboardBackup.save()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        do {
            try postPaste()
        } catch {
            // Transcript stays on the clipboard (already written) — the
            // guarantee is that it is never silently lost. Do not restore:
            // restoring would erase the transcript the user needs.
            return false
        }

        try await Task.sleep(for: restoreDelay)
        backup.restore()
        return true
    }

    /// Build and post keyDown/keyUp ⌘V (ANSI V = virtual key 9).
    /// Public so it can serve as the init default argument.
    public static func postSyntheticPaste() throws {
        guard AXIsProcessTrusted() else {
            throw InjectorError.accessibilityNotTrusted
        }

        let vKey: CGKeyCode = 9  // kVK_ANSI_V
        guard
            let keyDown = CGEvent(
                keyboardEventSource: nil, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(
                keyboardEventSource: nil, virtualKey: vKey, keyDown: false)
        else {
            throw InjectorError.eventPostFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
