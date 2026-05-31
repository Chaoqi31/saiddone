import AppKit
import SwiftUI

/// Live state for the recording overlay.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var level: Float = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 36)  // rolling waveform
    @Published var seconds: Int = 0
    @Published var label: String = "Recording"

    func pushLevel(_ v: Float) {
        level = v
        levels.removeFirst()
        levels.append(v)
    }
    func reset() {
        level = 0; seconds = 0
        levels = Array(repeating: 0, count: 36)
    }
}

/// Compact floating, non-activating overlay shown while recording: dot + label + timer + waveform.
/// Bottom-center, click-through.
@MainActor
final class RecordingOverlay {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var startDate: Date?

    func show(label: String) {
        model.reset()
        model.label = label
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

    func updateLevel(_ level: Float) { model.pushLevel(level) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
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
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 90))
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 8, height: 8)
                .opacity(model.seconds % 2 == 0 ? 1 : 0.35)
            waveform.frame(width: 130, height: 24)
            Spacer(minLength: 4)
            Text(timeString).font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 0)
        .frame(width: 240, height: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
    }

    private var timeString: String {
        String(format: "%d:%02d", model.seconds / 60, model.seconds % 60)
    }

    private var waveform: some View {
        GeometryReader { geo in
            let n = model.levels.count
            let w = max(1, (geo.size.width - CGFloat(n - 1) * 2) / CGFloat(n))
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<n, id: \.self) { i in
                    Capsule().fill(.red.gradient)
                        .frame(width: w, height: max(2, CGFloat(model.levels[i]) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: model.levels)
        }
    }
}
