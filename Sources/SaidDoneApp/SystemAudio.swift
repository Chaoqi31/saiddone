import Foundation

/// Mute/unmute system audio output (so playing media doesn't bleed into the mic while recording).
enum SystemAudio {
    static func setMuted(_ muted: Bool) {
        NSAppleScript(source: "set volume output muted \(muted)")?.executeAndReturnError(nil)
    }
}
