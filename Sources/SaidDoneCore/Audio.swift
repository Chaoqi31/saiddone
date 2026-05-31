import Foundation

/// Mono PCM audio at a known sample rate, ready for an ASR Provider.
/// ASR models (Qwen3-ASR, Whisper) expect 16 kHz mono float [-1, 1].
public struct AudioSamples: Sendable {
    public static let targetSampleRate: Double = 16_000

    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double = AudioSamples.targetSampleRate) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Duration in seconds.
    public var duration: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// True when short enough that the B1 (≤2s) latency bar applies (GOALS: short audio ≤15s).
    public var isShortUtterance: Bool { duration <= 15 }
}
