import AppKit

/// Subtle interaction sounds (macOS system sounds) for record start / result inserted.
enum SoundFx {
    static func start() { play("Tink") }
    static func done() { play("Pop") }
    private static func play(_ name: String) { NSSound(named: name)?.play() }
}
