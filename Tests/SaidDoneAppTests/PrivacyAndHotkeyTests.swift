import Foundation
import AppKit
import Testing
import SaidDoneCore
@testable import SaidDoneApp

@MainActor
struct PrivacyAndHotkeyTests {
    @Test func appControllerDoesNotLogTranscribedText() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SaidDoneApp/AppController.swift"))

        #expect(!(source.contains("RAW:")))
        #expect(!(source.contains("result.rawTranscript)'")))
        #expect(!(source.contains("result.text)'")))
    }

    @Test func pasteboardSnapshotRestoresString() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        snapshot.restore(to: pasteboard)

        #expect((pasteboard.string(forType: .string)) == "original")
        pasteboard.releaseGlobally()
    }

    @Test func fastDraftReplacementNeverUsesBlindUndo() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SaidDoneApp/InsertionService.swift"))

        #expect(!(source.contains("synthesizeCommandZ")))
    }

    @Test func fastDraftReplacementValidatesOriginalTargetAndCancelsClipboardRestore() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SaidDoneApp/InsertionService.swift"))

        #expect(source.contains("insertFastDraft"))
        #expect(source.contains("CFEqual"))
        #expect(source.contains("cancelPendingPasteboardRestore"))
    }

    @Test func fastDraftIsNotInsertedWhenTargetCannotBeSafelyReplaced() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SaidDoneApp/InsertionService.swift"))

        #expect(source.contains("guard let target = replaceableFastDraftTarget(for: text) else"))
        #expect(source.contains("AXUIElementIsAttributeSettable"))
    }

    @Test func duplicateHotkeysAreReported() {
        var config = AppConfig.default
        config.translationHotkey = config.dictationHotkey

        #expect((Set(AppController.duplicateHotkeyNames(config))) == (["Voice Input", "Translation"]))
    }

    @Test func mouseHotkeyDisplayAndDuplicates() {
        let side = Hotkey(mouseButton: 3)
        #expect(hotkeyDisplay(side).contains("4") || hotkeyDisplay(side).contains("侧"))

        var config = AppConfig.default
        config.askHotkey = Hotkey(mouseButton: 3)
        config.dictationHotkey = Hotkey(mouseButton: 3)
        #expect((Set(AppController.duplicateHotkeyNames(config))) == (["Ask Anything", "Voice Input"]))
    }

    @Test func recordingToggleIgnoresWhilePipelineBusy() {
        #expect((AppController.recordingToggleAction(activeMode: nil, isWorking: true, requested: .dictation)) == .ignoreBusy)
    }

    @Test func recordingToggleFinishesSameMode() {
        #expect((AppController.recordingToggleAction(activeMode: .dictation, isWorking: false, requested: .dictation)) == .finish)
    }

    @Test func recordingToggleSwitchesDifferentMode() {
        #expect((AppController.recordingToggleAction(activeMode: .dictation, isWorking: false, requested: .ask)) == (.switchMode(.ask)))
    }

    @Test func recordingToggleStartsWhenIdle() {
        #expect((AppController.recordingToggleAction(activeMode: nil, isWorking: false, requested: .translation(target: "en"))) == (.start(.translation(target: "en"))))
    }
}
