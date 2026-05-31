import AppKit
import SwiftUI

/// Live state for the recording overlay.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var level: Float = 0      // 0…1 mic level
    @Published var seconds: Int = 0      // elapsed
    @Published var label: String = "Recording"
}

/// Floating, non-activating panel shown while recording — gives the "I'm listening" feedback
/// that voxt/speaktype have. Bottom-center, click-through.
@MainActor
final class RecordingOverlay {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var startDate: Date?

    func show(label: String) {
        model.label = label
        model.seconds = 0
        model.level = 0
        startDate = Date()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.orderFrontRegardless()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startDate else { return }
                self.model.seconds = Int(Date().timeIntervalSince(s))
            }
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
    }

    func updateLevel(_ level: Float) { model.level = level }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 80))
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 10, height: 10)
                .opacity(model.seconds % 2 == 0 ? 1 : 0.3)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(model.label).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(timeString).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                level
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 220, height: 64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
    }

    private var timeString: String {
        String(format: "%d:%02d", model.seconds / 60, model.seconds % 60)
    }

    private var level: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                Capsule().fill(.red.gradient)
                    .frame(width: max(2, geo.size.width * CGFloat(model.level)), height: 4)
                    .animation(.easeOut(duration: 0.1), value: model.level)
            }
        }
        .frame(height: 4)
    }
}
