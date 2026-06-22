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
    @Published var processingProgress: Double = 0   // 0…1 deterministic pipeline progress
    @Published var processingStage = ""
    @Published var slowHint = false          // shown when processing drags (first-run model load)
    @Published var errorText: String?
    @Published var doneText: String?
    @Published var previewText = ""
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    func pushLevel(_ v: Float) { level = v; levels.removeFirst(); levels.append(v) }
    func reset() {
        level = 0; seconds = 0; processing = false; processingProgress = 0; processingStage = ""
        slowHint = false; errorText = nil; doneText = nil; previewText = ""
        levels = Array(repeating: 0, count: 30)
    }
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
        panel.setContentSize(NSSize(width: OverlayView.baseWidth, height: panel.frame.height))
        reposition(panel)
        panel.orderFrontRegardless()
        announce(label)
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
        timer?.invalidate()
        model.processing = true
        model.processingProgress = 0
        model.processingStage = NSLocalizedString("Processing…", comment: "overlay processing")
        model.slowHint = false
        // If the pipeline runs long (a cold first-run model load), say so instead of a silent spinner.
        timer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            Task { @MainActor in if self?.model.processing == true { self?.model.slowHint = true } }
        }
    }

    /// Briefly confirm success ("Inserted ✓") so finishing a dictation isn't silent, then dismiss.
    func showDone(_ message: String) {
        timer?.invalidate(); timer = nil
        model.processing = false
        model.errorText = nil
        model.doneText = message
        let panel = self.panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.orderFrontRegardless()
        announce(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            if self?.model.doneText == message { self?.hide() }
        }
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
        announce(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.model.errorText == message { self?.hide() }
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        model.processing = false
        model.errorText = nil
        model.doneText = nil
        panel?.orderOut(nil)
    }

    func updateLevel(_ level: Float) { model.pushLevel(level) }

    /// Update the deterministic 0…1 pipeline progress bar.
    func updateProcessing(progress: Double, stageKey: String) {
        model.processingProgress = min(1, max(0, progress))
        model.processingStage = localizedStage(stageKey)
    }

    private func localizedStage(_ key: String) -> String {
        switch key {
        case "transcribing":
            return NSLocalizedString("Transcribing…", comment: "overlay stage")
        case "polishing":
            return NSLocalizedString("Polishing…", comment: "overlay stage")
        case "rewriting", "asking":
            return NSLocalizedString("Thinking…", comment: "overlay stage")
        case "done":
            return NSLocalizedString("Inserting…", comment: "overlay stage")
        default:
            return NSLocalizedString("Processing…", comment: "overlay processing")
        }
    }

    func updatePreview(_ text: String) {
        model.previewText = text
        // Live preview needs room to read — widen the panel once text starts arriving.
        if let panel, !text.isEmpty, panel.frame.width != OverlayView.previewWidth {
            panel.setContentSize(NSSize(width: OverlayView.previewWidth, height: panel.frame.height))
            reposition(panel)
        }
    }

    /// Announce a state change to VoiceOver — the floating HUD wouldn't otherwise be read aloud, so a
    /// blind user has no idea recording started, a result was inserted, or an error occurred.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

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
    static let baseWidth: CGFloat = 300
    static let previewWidth: CGFloat = 440

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
            } else if let done = model.doneText {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(done).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
            } else if model.processing {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.slowHint
                             ? NSLocalizedString("Loading model…", comment: "overlay slow")
                             : model.processingStage)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        ProgressView(value: model.processingProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                            .animation(.easeOut(duration: 0.25), value: model.processingProgress)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 9) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .opacity(model.seconds % 2 == 0 ? 1 : 0.35)
                    if model.previewText.isEmpty {
                        waveform.frame(width: 96, height: 22)
                    } else {
                        Text(model.previewText).font(.system(size: 11)).lineLimit(2)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
        .frame(width: model.previewText.isEmpty ? Self.baseWidth : Self.previewWidth, height: 56)
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
