import AppKit
import XCTest
import SaidDoneCore
@testable import SaidDoneApp

@MainActor
final class PrivacyAndHotkeyTests: XCTestCase {
    func testAppControllerDoesNotLogTranscribedText() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SaidDoneApp/AppController.swift"))

        XCTAssertFalse(source.contains("RAW:"))
        XCTAssertFalse(source.contains("result.rawTranscript)'"))
        XCTAssertFalse(source.contains("result.text)'"))
    }

    func testPasteboardSnapshotRestoresString() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        snapshot.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        pasteboard.releaseGlobally()
    }

    func testDuplicateHotkeysAreReported() {
        var config = AppConfig.default
        config.translationHotkey = config.dictationHotkey

        XCTAssertEqual(AppController.duplicateHotkeyNames(config), ["Translation"])
    }
}
