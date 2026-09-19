import CoreGraphics
import Foundation

/// Watches for the Right-⌥+Space chord through a CGEventTap and reports
/// toggles on the main actor.
///
/// The tap is an active filter at the HID level: the chord's Space keyDown
/// (and its autorepeats) are swallowed so nothing is typed into the focused
/// app. The Right-⌥ press itself is passed through — the system needs it to
/// track the modifier, and a lone Right-⌥ is inert in most apps (accepted
/// v1 tradeoff). Modifier keys arrive as flagsChanged events, never as
/// keyDown/keyUp; the watcher arms on the right-⌥ device flag bit in those
/// events, the only signal that distinguishes right ⌥ from left. Tap
/// creation fails without Accessibility trust; the caller surfaces that as
/// the app's permission gate. A tap disabled by the system's timeout
/// watchdog is re-enabled automatically.
@MainActor
public final class HotkeyWatcher {
    public enum WatcherError: Error, Equatable {
        /// CGEvent.tapCreate returned nil — almost always missing
        /// Accessibility trust (or another active tap conflict).
        case tapCreationFailed
    }

    public typealias ChordHandler = @MainActor @Sendable (ChordMode) -> Void

    /// Which pipeline the chord engages. Plain Right-⌥+Space dictates
    /// verbatim; adding Shift makes it a one-shot command-mode utterance.
    public enum ChordMode: Equatable, Sendable {
        case dictation
        case command
    }

    /// kVK_RightOption — not in the public SDK headers as a constant.
    nonisolated public static let rightOptionKeyCode: CGKeyCode = 61  // 0x3D
    /// kVK_Space.
    nonisolated public static let spaceKeyCode: CGKeyCode = 49
    /// NX_DEVICERALTKEYMASK (0x40): the device-dependent flag bit marking
    /// the right ⌥ as held. The generic .maskAlternate can't tell left
    /// from right, and modifiers only ever arrive as flagsChanged.
    nonisolated public static let rightOptionDeviceFlag = CGEventFlags(
        rawValue: 0x40)

    private let onChord: ChordHandler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDown = false

    public init(onChord: @escaping ChordHandler) {
        self.onChord = onChord
    }

    /// Install the tap on the main run loop (common modes, so it survives
    /// menu tracking and modal sessions). Idempotent.
    public func start() throws {
        guard tap == nil else { return }

        let eventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: pfeiferChordTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            throw WatcherError.tapCreationFailed
        }

        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            self.tap = nil
            throw WatcherError.tapCreationFailed
        }
        self.runLoopSource = source
        CFRunLoopAddSource(RunLoop.main.getCFRunLoop(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Remove the tap. Idempotent. The owner must call this before
    /// releasing the watcher (Swift 6 forbids touching the non-Sendable
    /// run loop source from a nonisolated deinit); the app shell keeps
    /// the watcher for the process lifetime, so this is quit-time only.
    public func stop() {
        guard let tap, let runLoopSource else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopSourceInvalidate(runLoopSource)
        CFRunLoopRemoveSource(RunLoop.main.getCFRunLoop(), runLoopSource, .commonModes)
        self.runLoopSource = nil
        self.tap = nil
        rightOptionDown = false
    }

    // MARK: - Event classification (pure, unit-tested)

    /// What a tapped keyboard event means to the chord watcher.
    public enum EventClass: Equatable, Sendable {
        case rightOptionDown
        case rightOptionUp
        /// A Space keyDown while Right-⌥ is held; `autorepeat` distinguishes
        /// the initial press from held-down repeats (both are swallowed).
        /// `mode` reflects whether Shift was also held (command mode).
        case chordSpace(autorepeat: Bool, mode: ChordMode)
        case other
    }

    /// Classify a keyboard event against the Right-⌥(+Shift)+Space chord.
    /// Pure function of the event's fields — unit-tested with synthetic
    /// CGEvents, no tap or Accessibility trust needed. `rightOptionDown`
    /// is the watcher's tracked state (used for Space); the right-⌥ device
    /// bit itself is only carried by flagsChanged events, so
    /// `rightOptionDeviceDown` is consulted for those alone. `shiftDown`
    /// is read from the event's flags and only selects the chord's mode.
    nonisolated public static func classify(
        type: CGEventType,
        keyCode: Int64,
        autorepeat: Bool,
        rightOptionDown: Bool,
        rightOptionDeviceDown: Bool = false,
        shiftDown: Bool = false
    ) -> EventClass {
        // Modifiers arrive as flagsChanged: the keycode names the modifier
        // that changed and the event's flag bits hold its new state.
        if type == .flagsChanged {
            if keyCode == Int64(rightOptionKeyCode) {
                return rightOptionDeviceDown ? .rightOptionDown : .rightOptionUp
            }
            return .other
        }

        let isKeyDown = type == .keyDown
        switch keyCode {
        case Int64(rightOptionKeyCode):
            if isKeyDown { return .rightOptionDown }
            if type == .keyUp { return .rightOptionUp }
            return .other
        case Int64(spaceKeyCode):
            if isKeyDown && rightOptionDown {
                return .chordSpace(
                    autorepeat: autorepeat,
                    mode: shiftDown ? .command : .dictation)
            }
            return .other
        default:
            return .other
        }
    }

    // MARK: - Tap handling (main thread only, via the run loop source)

    /// Decide what to do with one tapped event. Must run on the main
    /// thread (the tap source lives on the main run loop). Returns true
    /// when the event should be swallowed (not delivered to the focused
    /// app); fires the chord handler when the chord's initial press is
    /// seen; re-arms the tap after a timeout disable.
    fileprivate func shouldSwallow(
        type: CGEventType,
        keyCode: Int64,
        autorepeat: Bool,
        rightOptionDeviceDown: Bool,
        shiftDown: Bool
    ) -> Bool {
        switch type {
        case .tapDisabledByTimeout:
            // The system disabled us for responding too slowly; re-arm.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false

        case .keyDown, .keyUp, .flagsChanged:
            switch Self.classify(
                type: type,
                keyCode: keyCode,
                autorepeat: autorepeat,
                rightOptionDown: rightOptionDown,
                rightOptionDeviceDown: rightOptionDeviceDown,
                shiftDown: shiftDown
            ) {
            case .rightOptionDown:
                rightOptionDown = true
                return false
            case .rightOptionUp:
                rightOptionDown = false
                return false
            case .chordSpace(_, let mode):
                // Swallow the chord (and its autorepeats) and toggle.
                if !autorepeat {
                    onChord(mode)
                }
                return true
            case .other:
                return false
            }

        default:
            return false
        }
    }
}

/// C-compatible tap callback — no captures; dispatches to the watcher on
/// the main thread. Safe for `MainActor.assumeIsolated` because the source
/// runs on the main run loop. CGEvent is not Sendable, so only Sendable
/// field values cross the isolation boundary; the pass-through/swallow
/// decision is applied to the original event here.
private func pfeiferChordTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let watcher = Unmanaged<HotkeyWatcher>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let rightOptionDeviceDown =
        event.flags.rawValue & HotkeyWatcher.rightOptionDeviceFlag.rawValue != 0
    let shiftDown = event.flags.contains(.maskShift)
    let swallow: Bool = MainActor.assumeIsolated {
        watcher.shouldSwallow(
            type: type,
            keyCode: keyCode,
            autorepeat: autorepeat,
            rightOptionDeviceDown: rightOptionDeviceDown,
            shiftDown: shiftDown
        )
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
