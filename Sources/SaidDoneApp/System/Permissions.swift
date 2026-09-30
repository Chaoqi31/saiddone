import AppKit
import ApplicationServices
import AVFoundation
import Observation
import SaidDoneCore

/// Microphone, Accessibility and 🌐-key state, refreshed when SaidDone becomes active and polled while Accessibility
/// is still missing (macOS sends no notification when it is granted).
@MainActor @Observable
final class PermissionsModel {
    private(set) var microphone: AVAuthorizationStatus
    private(set) var accessibility: Bool
    /// "Press 🌐 key to" is set to Do Nothing, so fn reaches SaidDone alone.
    private(set) var globeKeyFree: Bool

    @ObservationIgnored private var poll: Timer?

    init() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
        globeKeyFree = Self.readGlobeKeyFree()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        startPollingIfNeeded()
    }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
        globeKeyFree = Self.readGlobeKeyFree()
        startPollingIfNeeded()
    }

    func requestMicrophone() async {
        if microphone == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        refresh()
        if microphone != .authorized { open("Privacy_Microphone") }
    }

    /// Shows the system prompt the first time, then the settings pane.
    func requestAccessibility() {
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            open("Privacy_Accessibility")
        }
        startPollingIfNeeded()
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    private func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    private func startPollingIfNeeded() {
        guard !accessibility, poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.accessibility = AXIsProcessTrusted()
                self.globeKeyFree = Self.readGlobeKeyFree()
                if self.accessibility {
                    self.poll?.invalidate()
                    self.poll = nil
                }
            }
        }
    }

    /// Unset means the system default, which is never Do Nothing.
    private static func readGlobeKeyFree() -> Bool {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (value as? Int) == 0
    }
}

/// Readiness inputs, read live from the stores, so SwiftUI tracks them without any copy.
@MainActor
struct SetupStatus {
    let settings: SettingsStore
    let vault: Vault
    let library: ModelLibrary
    let permissions: PermissionsModel

    var facts: SetupFacts {
        SetupFacts(microphoneAllowed: permissions.microphone == .authorized,
                   accessibilityAllowed: permissions.accessibility,
                   globeKeyFree: permissions.globeKeyFree,
                   installed: library.installed,
                   credentials: vault.state == .loading ? Self.everyVendor : vault.present)
    }

    var issues: [Issue] { Readiness.issues(settings.prefs, facts) }
    var recordingBlocker: Issue? { Readiness.recordingBlocker(settings.prefs, facts) }

    /// Until the Keychain has been read, a missing key is not reported: it is probably there.
    private static let everyVendor = Set((CloudPreset.chat + CloudPreset.speech).map(\.id) + [VendorID.volcengine])
}
