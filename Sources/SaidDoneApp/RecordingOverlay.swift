import AppKit
import SwiftUI

/// Live state + actions for the recording overlay.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var level: Float = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 30)
    @Published var seconds: Int = 0
    @Published var label: String = "Recording"
    @Published var processing = false
    @Published var errorText: String?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    func pushLevel(_ v: Float) { level = v; levels.removeFirst(); levels.append(v) }
    func reset() { level = 0; seconds = 0; processing = false; errorText = nil; levels = Array(repeating: 0, count: 30) }
}

/// Floating, click-through-except-buttons overlay: dot + waveform + timer + ✓/✕ while recording,
/// spinner while the pipeline runs.
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
                guard let self, let s = self.startDate, !self.model.processing else { return }
                self.model.seconds = Int(Date().timeIntervalSince(s))
            }
        }
    }

    /// Switch to the "processing" state (keep panel up with a spinner) after the user stops.
    func showProcessing() {
        timer?.invalidate(); timer = nil
        model.processing = true
    }

    /// Show an error in the overlay for a few seconds, then dismiss (so failures aren't silent).
    func showError(_ message: String) {
        timer?.invalidate(); timer = nil
        model.processing = false
        model.errorText = message
        let panel = self.panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.model.errorText == message { self?.hide() }
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        model.processing = false
        model.errorText = nil
        panel?.orderOut(nil)
    }

    func updateLevel(_ level: Float) { model.pushLevel(level) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false   // buttons need clicks
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
        Group {
            if let err = model.errorText {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            } else if model.processing {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Processing…").font(.system(size: 12, weight: .medium))
                        ProgressView().progressViewStyle(.linear).frame(width: 200)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 9) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .opacity(model.seconds % 2 == 0 ? 1 : 0.35)
                    waveform.frame(width: 96, height: 22)
                    Text(timeString).font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Button { model.onFinish?() } label: { Image(systemName: "checkmark") }
                        .help("Finish & insert")
                    Button { model.onCancel?() } label: { Image(systemName: "xmark") }
                        .help("Cancel")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 300, height: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
    }

    private var timeString: String { String(format: "%d:%02d", model.seconds / 60, model.seconds % 60) }

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
