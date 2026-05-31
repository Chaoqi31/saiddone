import XCTest
@testable import SaidDoneCore

final class HistoryTests: XCTestCase {
    func testAppendAndRecentNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1000)
        store.append(.init(date: t0, mode: "dictation", raw: "a", text: "A"))
        store.append(.init(date: t0.addingTimeInterval(1), mode: "translation", raw: "b", text: "B"))

        let recent = store.recent()
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.text, "B")   // newest first
        XCTAssertEqual(recent.last?.text, "A")
    }

    func testRecentLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        for i in 0..<5 { store.append(.init(date: Date(timeIntervalSince1970: Double(i)), mode: "dictation", raw: "\(i)", text: "\(i)")) }
        XCTAssertEqual(store.recent(2).map(\.text), ["4", "3"])
    }

    func testEmpty() {
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(store.recent(), [])
    }
}
