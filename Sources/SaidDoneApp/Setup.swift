import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import SaidDoneCore
import SaidDoneProviders

/// Onboarding/status: permissions + model readiness, shown in the main window.
@MainActor
final class SetupModel: ObservableObject {
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var asrReady = false
    @Published var llmReady = false
    @Published var asrLocal = true
    @Published var llmLocal = true
    @Published var busy = false
    @Published var status = ""

    @Published var downloadProgress: Double?
    @Published var llmDownloadProgress: Double?
    @Published var useMirror = false
    var asrModelID: String = ""
    var llmModelID: String = ""
    private var cloud = CloudConfig()
    var onPrepare: (() async -> Void)?
    var onDownloadASR: ((@escaping @Sendable (Double) -> Void) async throws -> Void)?
    var onDownloadLLM: ((@escaping @Sendable (Double) -> Void) async throws -> Void)?
    var onSetMirror: ((Bool) -> Void)?

    func setMirror(_ on: Bool) { useMirror = on; onSetMirror?(on) }

    func sync(from config: AppConfig) {
        asrLocal = config.asr.location == .local
        llmLocal = config.llm.location == .local
        asrModelID = config.asr.modelID
        llmModelID = config.llm.modelID
        cloud = config.cloud
        refresh()
    }

    func downloadASR() {
        downloadProgress = 0
        status = NSLocalizedString("Downloading speech model…", comment: "setup status")
        Task {
            do {
                try await onDownloadASR? { p in Task { @MainActor in self.downloadProgress = p } }
                status = NSLocalizedString("Speech model ready", comment: "setup status")
            } catch {
                status = NSLocalizedString("Download failed — check network / HuggingFace access", comment: "setup status")
            }
            downloadProgress = nil; refresh()
        }
    }

    func downloadLLM() {
        llmDownloadProgress = 0
        status = NSLocalizedString("Downloading AI model…", comment: "setup status")
        Task {
            do {
                try await onDownloadLLM? { p in Task { @MainActor in self.llmDownloadProgress = p } }
                status = NSLocalizedString("AI model ready", comment: "setup status")
            } catch {
                status = NSLocalizedString("Download failed — check network / HuggingFace access", comment: "setup status")
            }
            llmDownloadProgress = nil; refresh()
        }
    }

    var modelsPath: String {
        var paths: [String] = []
        if asrLocal {
            paths.append("Speech: \(ModelStorage.whisperCanonicalBase.path(percentEncoded: false))")
        }
        if llmLocal {
            paths.append("AI: \(ModelStorage.mlxModelsRoot.path(percentEncoded: false))")
        }
        return paths.joined(separator: " · ")
    }
    func revealModelsFolder() {
        var roots: [URL] = []
        if asrLocal { roots.append(ModelStorage.whisperCanonicalBase) }
        if llmLocal { roots.append(ModelStorage.mlxModelsRoot) }
        for root in roots {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        }
    }

    func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
        asrReady = asrLocal
            ? ModelStorage.isWhisperReady(modelID: asrModelID)
            : EngineReadiness.cloudSpeechConfigured(cloud)
        llmReady = llmLocal
            ? ModelStorage.isMLXReady(modelID: llmModelID)
            : EngineReadiness.cloudAIConfigured(cloud)
    }

    func prepare() {
        busy = true
        status = NSLocalizedString("Preparing selected engines…", comment: "setup status")
        Task {
            await onPrepare?()
            busy = false
            status = NSLocalizedString("Ready", comment: "setup status")
            refresh()
        }
    }

}

struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setup").font(.title2.bold())
            section("Permissions") {
                row("Microphone", model.micGranted, "Privacy_Microphone")
                row("Accessibility (paste into apps)", model.axGranted, "Privacy_Accessibility")
            }
            section("Engine readiness") {
                row(model.asrLocal ? "Speech — Local (WhisperKit)" : "Speech — Cloud",
                    model.asrReady, nil)
                if !model.asrLocal, !model.asrReady {
                    Text("Complete cloud speech settings in the Cloud tab.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.asrLocal, !model.asrReady {
                    HStack {
                        Button(model.downloadProgress != nil
                               ? NSLocalizedString("Downloading…", comment: "setup button")
                               : NSLocalizedString("Download speech model", comment: "setup button")) { model.downloadASR() }
                            .disabled(model.downloadProgress != nil)
                        if let p = model.downloadProgress { ProgressView(value: p).frame(width: 160) }
                    }
                }
                row(model.llmLocal ? "AI — Local" : "AI — Cloud", model.llmReady, nil)
                if !model.llmLocal, !model.llmReady {
                    Text("Complete cloud AI settings in the Cloud tab.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.llmLocal, !model.llmModelID.isEmpty {
                    Text(verbatim: model.llmModelID)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if model.llmLocal, !model.llmReady {
                    HStack {
                        Button(model.llmDownloadProgress != nil
                               ? NSLocalizedString("Downloading…", comment: "setup button")
                               : NSLocalizedString("Download AI model", comment: "setup button")) { model.downloadLLM() }
                            .disabled(model.llmDownloadProgress != nil)
                        if let p = model.llmDownloadProgress { ProgressView(value: p).frame(width: 160) }
                    }
                }
                if model.asrLocal || model.llmLocal {
                    Toggle(NSLocalizedString("Downloads are slow? Use the China mirror (hf-mirror.com)", comment: "setup mirror"),
                           isOn: Binding(get: { model.useMirror }, set: { model.setMirror($0) }))
                        .font(.caption)
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("Saved to \(model.modelsPath)").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Show in Finder") { model.revealModelsFolder() }.buttonStyle(.link)
                            .fixedSize()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Cloud engines do not require model downloads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(model.busy
                       ? NSLocalizedString("Preparing engines…", comment: "setup button")
                       : NSLocalizedString("Prepare engines", comment: "setup button")) { model.prepare() }
                    .disabled(model.busy)
                Button("Refresh") { model.refresh() }
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.refresh() }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: LocalizedStringKey, _ ok: Bool, _ prefPane: String?) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(label)
            Spacer()
            if !ok, let prefPane {
                Button("Grant") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(prefPane)")!)
                }.controlSize(.small)
            }
        }
    }
}
