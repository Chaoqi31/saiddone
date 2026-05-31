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

    /// Encode to a 16-bit PCM WAV (for cloud upload and saving to history).
    public func wavData() -> Data {
        let rate = Int(sampleRate)
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var d = Data(capacity: 44 + dataSize)
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * bytesPerSample)); u16(UInt16(bytesPerSample)); u16(16)
        str("data"); u32(UInt32(dataSize))
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }
}
