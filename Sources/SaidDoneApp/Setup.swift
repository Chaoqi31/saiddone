import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices

/// Onboarding/status: permissions + model readiness, shown in the main window.
@MainActor
final class SetupModel: ObservableObject {
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var asrReady = false
    @Published var llmReady = false
    @Published var busy = false
    @Published var status = ""

    @Published var downloadProgress: Double?
    var llmModelID: String = ""
    var onPrepare: (() async -> Void)?
    var onDownloadASR: ((@escaping @Sendable (Double) -> Void) async throws -> Void)?

    func downloadASR() {
        busy = true; downloadProgress = 0
        status = NSLocalizedString("Downloading speech model…", comment: "setup status")
        Task {
            do {
                try await onDownloadASR? { p in Task { @MainActor in self.downloadProgress = p } }
                status = NSLocalizedString("Speech model ready", comment: "setup status")
            } catch {
                status = NSLocalizedString("Download failed — check network / HuggingFace access", comment: "setup status")
            }
            busy = false; downloadProgress = nil; refresh()
        }
    }

    func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
        asrReady = Self.dirNonEmpty(Self.modelsRoot.appendingPathComponent("argmaxinc/whisperkit-coreml"))
        let llmDir = Self.modelsRoot.appendingPathComponent(llmModelID)
        llmReady = FileManager.default.fileExists(atPath: llmDir.appendingPathComponent("config.json").path)
    }

    func prepare() {
        busy = true; status = NSLocalizedString("Loading models… (first run downloads, 20–60s)", comment: "setup status")
        Task {
            await onPrepare?()
            busy = false; status = NSLocalizedString("Ready", comment: "setup status")
            refresh()
        }
    }

    static var modelsRoot: URL {
        URL.documentsDirectory.appending(path: "huggingface/models", directoryHint: .isDirectory)
    }
    static func dirNonEmpty(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty == false) ?? false
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
            section("Models (on-device)") {
                row("Speech (WhisperKit)", model.asrReady, nil)
                if !model.asrReady {
                    HStack {
                        Button(model.busy
                               ? NSLocalizedString("Downloading…", comment: "setup button")
                               : NSLocalizedString("Download speech model", comment: "setup button")) { model.downloadASR() }
                            .disabled(model.busy)
                        if let p = model.downloadProgress { ProgressView(value: p).frame(width: 160) }
                    }
                }
                row("LLM (\(model.llmModelID.isEmpty ? "local" : model.llmModelID))", model.llmReady, nil)
                if !model.llmReady {
                    Text("Missing LLM model → download it (or run `scripts/get-models.sh`), or pick “Rule-based only” in Providers. SaidDone never silently switches engines.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(model.busy
                       ? NSLocalizedString("Preparing…", comment: "setup button")
                       : NSLocalizedString("Prepare / Warm models", comment: "setup button")) { model.prepare() }
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
