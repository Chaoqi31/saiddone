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

    var llmModelID: String = ""
    var onPrepare: (() async -> Void)?

    func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
        asrReady = Self.dirNonEmpty(Self.modelsRoot.appendingPathComponent("argmaxinc/whisperkit-coreml"))
        let llmDir = Self.modelsRoot.appendingPathComponent(llmModelID)
        llmReady = FileManager.default.fileExists(atPath: llmDir.appendingPathComponent("config.json").path)
    }

    func prepare() {
        busy = true; status = "Loading models… (first run downloads, 20–60s)"
        Task {
            await onPrepare?()
            busy = false; status = "Ready"; refresh()
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
                row("LLM (\(model.llmModelID.isEmpty ? "local" : model.llmModelID))", model.llmReady, nil)
                if !model.llmReady {
                    Text("Missing LLM → run `scripts/get-models.sh` to download, or it falls back to rule-based polish.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(model.busy ? "Preparing…" : "Prepare / Warm models") { model.prepare() }
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

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ ok: Bool, _ prefPane: String?) -> some View {
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
