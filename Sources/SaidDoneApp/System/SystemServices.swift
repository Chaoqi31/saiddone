import AppKit
import CoreAudio
import Observation
import ServiceManagement
import SwiftUI

// MARK: - Output mute

/// Mutes the default output while recording so playing media doesn't bleed into the microphone. The token exists
/// only when SaidDone did the muting, so a user who was already muted stays muted afterwards.
struct MuteToken {
    let device: AudioDeviceID

    static func muteOutput() -> MuteToken? {
        guard let device = defaultOutput(), muted(device) == false, setMuted(device, true) else { return nil }
        return MuteToken(device: device)
    }

    func restore() { _ = Self.setMuted(device, false) }

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// nil when the device has no mute control.
    private static func muted(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}

// MARK: - Sounds

enum Sounds {
    case start, done, failed

    func play() {
        let name = switch self {
        case .start: "Tink"
        case .done: "Pop"
        case .failed: "Basso"
        }
        NSSound(named: name)?.play()
    }
}

// MARK: - Launch at login

/// The system owns this setting; reading it back is the only source of truth.
@MainActor @Observable
final class LoginItem {
    private(set) var enabled = SMAppService.mainApp.status == .enabled
    private(set) var needsApproval = SMAppService.mainApp.status == .requiresApproval

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
        }
        enabled = SMAppService.mainApp.status == .enabled
        needsApproval = SMAppService.mainApp.status == .requiresApproval
        if needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

// MARK: - Observation for AppKit

/// Runs `apply` with the value `read` produces now and again whenever the observable state it reads changes.
/// AppKit consumers (status icon, panels, the hotkey Esc flag) use this instead of copies kept in sync.
@MainActor
enum Observe {
    static func track<T: Equatable>(_ read: @escaping @MainActor () -> T, apply: @escaping @MainActor (T) -> Void) {
        Tracker(read: read, apply: apply).step()
    }

    /// Kept alive by the pending change handler of whatever it observes.
    @MainActor
    private final class Tracker<T: Equatable> {
        let read: @MainActor () -> T
        let apply: @MainActor (T) -> Void
        var last: T?

        init(read: @escaping @MainActor () -> T, apply: @escaping @MainActor (T) -> Void) {
            self.read = read
            self.apply = apply
        }

        func step() {
            let value = withObservationTracking { read() } onChange: {
                Task { @MainActor in self.step() }
            }
            if value != last {
                last = value
                apply(value)
            }
        }
    }
}
