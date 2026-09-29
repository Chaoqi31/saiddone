import Foundation
import Testing
@testable import SaidDoneCore

/// Drives a recognizer with a fake clock and records the gestures it emits.
private struct Keyboard {
    var recognizer = ShortcutRecognizer(.default)
    let t0 = ContinuousClock.now
    var now: Duration = .zero
    var escapeIsLive = false
    var gestures: [Gesture] = []
    var swallowed: [RawInput] = []
    var pendingWake: ContinuousClock.Instant?

    mutating func send(_ input: RawInput) {
        let reaction = recognizer.handle(input, at: t0 + now, escapeIsLive: escapeIsLive)
        gestures += reaction.gestures
        if reaction.swallow { swallowed.append(input) }
        if let wake = reaction.wakeAt { pendingWake = wake }
    }

    /// Advance time, firing a scheduled wake-up the way the tap host's timer would.
    mutating func wait(_ duration: Duration) {
        let target = t0 + now + duration
        if let wake = pendingWake, wake <= target {
            pendingWake = nil
            gestures += recognizer.tick(at: wake).gestures
        }
        now += duration
    }

    mutating func hold(_ keys: Set<ModifierKey>, _ flags: ModifierFlags = []) {
        send(.modifiers(held: keys, flags: flags))
    }
}

private func mode(_ gesture: Gesture) -> Mode? {
    switch gesture {
    case let .pressed(mode, _), let .retargeted(mode, _), let .released(mode, _, _): mode
    case .aborted, .escape: nil
    }
}

struct ShortcutRecognizerTests {
    @Test func quickFnTapPressesAndReleasesOnKeyUp() {
        var kb = Keyboard()
        kb.hold([.fn])
        kb.wait(.milliseconds(90))
        #expect(kb.gestures.isEmpty)
        kb.hold([])
        #expect(kb.gestures.count == 2)
        guard case .pressed(.dictation, let id) = kb.gestures[0],
              case .released(.dictation, id, let held) = kb.gestures[1] else {
            Issue.record("expected press + release, got \(kb.gestures)")
            return
        }
        #expect(held == .milliseconds(90))
    }

    @Test func heldFnPressesAfterArmDelay() {
        var kb = Keyboard()
        kb.hold([.fn])
        kb.wait(.milliseconds(149))
        #expect(kb.gestures.isEmpty)
        kb.wait(.milliseconds(10))
        guard case .pressed(.dictation, _) = kb.gestures.first else {
            Issue.record("expected press after the arm delay, got \(kb.gestures)")
            return
        }
        kb.wait(.seconds(2))
        kb.hold([])
        guard case .released(.dictation, _, let held) = kb.gestures.last else {
            Issue.record("expected release")
            return
        }
        #expect(held > .seconds(2))
    }

    @Test func fnUsedAsModifierForAnotherKeyNeverFires() {
        var kb = Keyboard()
        kb.hold([.fn])
        kb.wait(.milliseconds(60))
        kb.send(.keyDown(KeyCode(51), flags: [], isRepeat: false))   // ⌫ → forward delete
        kb.wait(.milliseconds(300))
        kb.send(.keyUp(KeyCode(51)))
        kb.hold([])
        #expect(kb.gestures.isEmpty)
        #expect(kb.swallowed.isEmpty, "fn+⌫ must still reach the app")
    }

    @Test func keyAfterTheChordFiredAbortsIt() {
        var kb = Keyboard()
        kb.hold([.fn])
        kb.wait(.milliseconds(200))
        kb.send(.keyDown(KeyCode(123), flags: [], isRepeat: false))  // ←
        kb.hold([])
        #expect(kb.gestures.count == 2)
        guard case .pressed(.dictation, let id) = kb.gestures[0], case .aborted(id) = kb.gestures[1] else {
            Issue.record("expected press then abort, got \(kb.gestures)")
            return
        }
    }

    @Test func strayKeyLongIntoAHoldDoesNotAbort() {
        var kb = Keyboard()
        kb.hold([.fn])
        kb.wait(.seconds(3))
        kb.send(.keyDown(KeyCode(0), flags: [], isRepeat: false))
        kb.hold([])
        #expect(kb.gestures.map(mode) == [.dictation, .dictation])
        guard case .released = kb.gestures.last else {
            Issue.record("the hold must still end with a release")
            return
        }
    }

    @Test func chordBuiltBeforeTheArmDelayFiresAsTheChord() {
        var kb = Keyboard()
        kb.hold([.fn])
        kb.wait(.milliseconds(40))
        kb.hold([.fn], .shift)
        kb.wait(.milliseconds(40))
        kb.hold([.fn])            // ⇧ released first…
        kb.wait(.milliseconds(20))
        kb.hold([])               // …then fn: still a translation tap
        #expect(kb.gestures.map(mode) == [.translation, .translation])
    }

    @Test func chordGrowingAfterPressRetargetsAndNeverDowngrades() {
        var kb = Keyboard()
        kb.hold([.fn])
        kb.wait(.milliseconds(400))
        kb.hold([.fn], .shift)
        kb.wait(.milliseconds(400))
        kb.hold([.fn])
        kb.wait(.milliseconds(50))
        kb.hold([])
        #expect(kb.gestures.count == 3)
        guard case .pressed(.dictation, let id) = kb.gestures[0],
              case .retargeted(.translation, id) = kb.gestures[1],
              case .released(.translation, id, _) = kb.gestures[2] else {
            Issue.record("expected press, retarget, release; got \(kb.gestures)")
            return
        }
    }

    @Test func releasingKeysNeverPressesAChord() {
        var kb = Keyboard()
        kb.hold([], .shift)       // left ⇧ first: not a solo key
        kb.hold([.fn], .shift)    // fn joins → arms fn⇧
        kb.wait(.milliseconds(200))
        #expect(kb.gestures.map(mode) == [.translation])
        kb.hold([], .shift)       // fn up → release
        kb.hold([], [])
        kb.hold([.fn])            // a genuinely new press
        kb.hold([])
        #expect(kb.gestures.map(mode) == [.translation, .translation, .dictation, .dictation])
    }

    @Test func boundComboIsSwallowedAndRepeatsAreSilent() {
        var kb = Keyboard()
        let d = KeyCode(2)
        kb.send(.keyDown(d, flags: [.control, .option], isRepeat: false))
        kb.send(.keyDown(d, flags: [.control, .option], isRepeat: true))
        kb.wait(.milliseconds(500))
        kb.send(.keyUp(d))
        #expect(kb.swallowed.count == 3)
        #expect(kb.gestures.count == 2)
        guard case .released(.dictation, _, let held) = kb.gestures.last else {
            Issue.record("expected a release")
            return
        }
        #expect(held == .milliseconds(500))
    }

    @Test func unboundComboPassesThrough() {
        var kb = Keyboard()
        kb.send(.keyDown(KeyCode(8), flags: [.command], isRepeat: false))   // ⌘C
        #expect(kb.swallowed.isEmpty)
        #expect(kb.gestures.isEmpty)
    }

    @Test func escapeIsSwallowedOnlyWhileLive() {
        var kb = Keyboard()
        kb.send(.keyDown(.escape, flags: [], isRepeat: false))
        #expect(kb.gestures.isEmpty)
        #expect(kb.swallowed.isEmpty)
        kb.escapeIsLive = true
        kb.send(.keyDown(.escape, flags: [], isRepeat: false))
        #expect(kb.gestures == [.escape])
        #expect(kb.swallowed.count == 1)
    }

    @Test func boundMouseButtonPressesAndReleases() {
        var kb = Keyboard()
        _ = kb.recognizer.update(Shortcuts([.mouse(MouseButton(3)!): .dictation]))
        kb.send(.mouseDown(3))
        kb.send(.mouseUp(3))
        kb.send(.mouseDown(1))
        #expect(kb.gestures.map(mode) == [.dictation, .dictation])
        #expect(kb.swallowed == [.mouseDown(3), .mouseUp(3)])
    }

    @Test func rightOptionAloneIsDistinctFromItsFlag() {
        var kb = Keyboard()
        _ = kb.recognizer.update(Shortcuts([.modifierKey(.rightOption, with: []): .dictation]))
        kb.hold([], .option)                  // left ⌥: nothing
        kb.hold([], [])
        #expect(kb.gestures.isEmpty)
        kb.hold([.rightOption], .option)      // right ⌥ sets its own flag, which is not an extra modifier
        kb.hold([], [])
        #expect(kb.gestures.map(mode) == [.dictation, .dictation])
    }

    @Test func resetReleasesAGestureInFlight() {
        var kb = Keyboard()
        kb.hold([.fn])
        kb.wait(.milliseconds(200))
        let releases = kb.recognizer.reset()
        guard case .released(.dictation, _, .zero) = releases.first else {
            Issue.record("expected a zero-length release, got \(releases)")
            return
        }
        kb.hold([])
        #expect(kb.gestures.count == 1, "no second release after the reset")
    }
}

struct TriggerCaptureTests {
    @Test func capturesTheWidestModifierChordOnRelease() {
        var capture = TriggerCapture()
        #expect(capture.handle(.modifiers(held: [.fn], flags: [])) == .listening)
        #expect(capture.handle(.modifiers(held: [.fn], flags: .shift)) == .listening)
        #expect(capture.handle(.modifiers(held: [.fn], flags: [])) == .listening)
        #expect(capture.handle(.modifiers(held: [], flags: [])) == .captured(.modifierKey(.fn, with: .shift)))
    }

    @Test func capturesCombosMouseAndCancels() {
        var capture = TriggerCapture()
        #expect(capture.handle(.keyDown(KeyCode(0), flags: [], isRepeat: false)) == .listening)
        #expect(capture.handle(.keyDown(KeyCode(2), flags: [.control, .option], isRepeat: false))
                == .captured(.keyCombo(KeyCode(2), [.control, .option])))
        var mouse = TriggerCapture()
        #expect(mouse.handle(.mouseDown(1)) == .listening)
        #expect(mouse.handle(.mouseDown(4)) == .captured(.mouse(MouseButton(4)!)))
        var esc = TriggerCapture()
        #expect(esc.handle(.keyDown(.escape, flags: [], isRepeat: false)) == .cancelled)
    }

    @Test func leftSideModifiersAloneAreNotATrigger() {
        var capture = TriggerCapture()
        #expect(capture.handle(.modifiers(held: [], flags: .command)) == .listening)
        #expect(capture.handle(.modifiers(held: [], flags: [])) == .listening)
    }
}

struct ShortcutsTests {
    @Test func bindingMovesATriggerBetweenModes() {
        var shortcuts = Shortcuts.default
        #expect(shortcuts.bind(.fn, to: .ask) == .dictation)
        #expect(shortcuts.mode(for: .fn) == .ask)
        #expect(!shortcuts.triggers(for: .dictation).contains(.fn))
        #expect(shortcuts.bind(.fn, to: .ask) == nil)
    }

    @Test func combosNeedAModifierUnlessFunctionKey() {
        #expect(Trigger.combo(KeyCode(2), []) == nil)
        #expect(Trigger.combo(KeyCode(2), .shift) == nil)
        #expect(Trigger.combo(KeyCode(2), .command) != nil)
        #expect(Trigger.combo(KeyCode(105), []) != nil)   // F13
        #expect(Trigger.combo(.escape, .command) == nil)
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Shortcuts.default)
        #expect(try JSONDecoder().decode(Shortcuts.self, from: data) == .default)
    }
}
