import CoreGraphics
@testable import PfeiferCore
import Testing

@Suite
struct HotkeyWatcherClassificationTests {
    private func makeKeyEvent(
        keyCode: CGKeyCode,
        keyDown: Bool,
        autorepeat: Bool = false
    ) -> (type: CGEventType, keyCode: Int64, autorepeat: Bool) {
        let event = CGEvent(
            keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)!
        if autorepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        return (
            type: keyDown ? .keyDown : .keyUp,
            keyCode: Int64(keyCode),
            autorepeat: autorepeat
        )
    }

    @Test
    func rightOptionDownAndUpAreTracked() {
        let down = makeKeyEvent(keyCode: HotkeyWatcher.rightOptionKeyCode, keyDown: true)
        #expect(
            HotkeyWatcher.classify(
                type: down.type, keyCode: down.keyCode, autorepeat: false,
                rightOptionDown: false
            ) == .rightOptionDown)

        let up = makeKeyEvent(keyCode: HotkeyWatcher.rightOptionKeyCode, keyDown: false)
        #expect(
            HotkeyWatcher.classify(
                type: up.type, keyCode: up.keyCode, autorepeat: false,
                rightOptionDown: true
            ) == .rightOptionUp)
    }

    @Test
    func spaceWithRightOptionIsTheChord() {
        let space = makeKeyEvent(keyCode: HotkeyWatcher.spaceKeyCode, keyDown: true)
        #expect(
            HotkeyWatcher.classify(
                type: space.type, keyCode: space.keyCode, autorepeat: false,
                rightOptionDown: true
            ) == .chordSpace(autorepeat: false))
    }

    @Test
    func spaceAutorepeatIsAChordButFlagged() {
        let space = makeKeyEvent(
            keyCode: HotkeyWatcher.spaceKeyCode, keyDown: true, autorepeat: true)
        #expect(
            HotkeyWatcher.classify(
                type: space.type, keyCode: space.keyCode, autorepeat: true,
                rightOptionDown: true
            ) == .chordSpace(autorepeat: true))
    }

    @Test
    func spaceWithoutRightOptionIsOrdinary() {
        // Left-⌥ (or no modifier) + Space is the user's own typing.
        let space = makeKeyEvent(keyCode: HotkeyWatcher.spaceKeyCode, keyDown: true)
        #expect(
            HotkeyWatcher.classify(
                type: space.type, keyCode: space.keyCode, autorepeat: false,
                rightOptionDown: false
            ) == .other)
    }

    @Test
    func spaceKeyUpIsNeverTheChord() {
        let spaceUp = makeKeyEvent(keyCode: HotkeyWatcher.spaceKeyCode, keyDown: false)
        #expect(
            HotkeyWatcher.classify(
                type: spaceUp.type, keyCode: spaceUp.keyCode, autorepeat: false,
                rightOptionDown: true
            ) == .other)
    }

    @Test
    func otherKeysAreOrdinary() {
        for key: CGKeyCode in [0, 8, 36, 51, 125] {
            let event = makeKeyEvent(keyCode: key, keyDown: true)
            #expect(
                HotkeyWatcher.classify(
                    type: event.type, keyCode: event.keyCode, autorepeat: false,
                    rightOptionDown: true
                ) == .other)
        }
    }

    @Test
    func nonKeyEventsAreOrdinary() {
        #expect(
            HotkeyWatcher.classify(
                type: .flagsChanged, keyCode: Int64(HotkeyWatcher.spaceKeyCode),
                autorepeat: false, rightOptionDown: true
            ) == .other)
    }

    @Test
    func rightOptionComesThroughFlagsChanged() {
        // Real modifier presses arrive as flagsChanged (never keyDown/keyUp);
        // the right-⌥ device bit in the event's flags is the down/up signal.
        // Regression test: the tap once listened for keyDown/keyUp only and
        // never saw Right-⌥ at all, so the chord could not fire.
        #expect(
            HotkeyWatcher.classify(
                type: .flagsChanged,
                keyCode: Int64(HotkeyWatcher.rightOptionKeyCode),
                autorepeat: false,
                rightOptionDown: false,
                rightOptionDeviceDown: true
            ) == .rightOptionDown)

        #expect(
            HotkeyWatcher.classify(
                type: .flagsChanged,
                keyCode: Int64(HotkeyWatcher.rightOptionKeyCode),
                autorepeat: false,
                rightOptionDown: true,
                rightOptionDeviceDown: false
            ) == .rightOptionUp)
    }

    @Test
    func leftOptionFlagsChangedIsIgnored() {
        // kVK_LeftOption (58) never arms the chord — only the right one does.
        #expect(
            HotkeyWatcher.classify(
                type: .flagsChanged,
                keyCode: 58,
                autorepeat: false,
                rightOptionDown: false,
                rightOptionDeviceDown: true
            ) == .other)
    }
}
