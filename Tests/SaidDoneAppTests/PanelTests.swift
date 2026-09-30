import AppKit
import Observation
import SwiftUI
import Testing
@testable import SaidDoneApp

@MainActor @Observable
private final class Height {
    var value: CGFloat = 40
}

private struct Bar: View {
    let height: Height
    var body: some View { Color.red.frame(width: 300, height: height.value) }
}

/// A FloatingPanel follows its content's size and keeps its bottom edge where it was placed, so the voice bar grows
/// upward when a notice appears above it.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SAIDDONE_UI"] != nil))
struct PanelTests {
    @Test func growingContentKeepsTheBottomEdge() throws {
        _ = NSApplication.shared
        let height = Height()
        let panel = FloatingPanel(Bar(height: height))
        panel.present(at: .bottom)
        RunLoop.current.run(until: .now.addingTimeInterval(0.3))
        let before = panel.frame
        height.value = 120
        RunLoop.current.run(until: .now.addingTimeInterval(0.3))
        let after = panel.frame
        print("panel before \(before) after \(after)")
        #expect(before.height == 40)
        #expect(after.height == 120)
        #expect(abs(after.minY - before.minY) < 1, "bottom moved from \(before.minY) to \(after.minY)")
    }
}
