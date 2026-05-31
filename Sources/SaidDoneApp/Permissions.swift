import AVFoundation
import ApplicationServices

/// Mic + Accessibility grants. Zero-key startup (GOALS B4) still needs these two TCC grants.
enum Permissions {
    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Accessibility needed for CGEvent paste (ADR-0005) and reading foreground URL (App Profile).
    @discardableResult
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt (the global is not concurrency-safe in Swift 6).
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
