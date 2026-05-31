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

    /// Trim leading/trailing silence (with a small pad). Whisper hallucinates subtitle outros
    /// ("谢谢大家"…) on trailing silence, so cutting it removes the root cause + speeds ASR.
    public func trimmedSilence(threshold: Float = 0.012, windowMs: Double = 30, padMs: Double = 120) -> AudioSamples {
        guard !samples.isEmpty, sampleRate > 0 else { return self }
        let win = max(1, Int(sampleRate * windowMs / 1000))
        func loud(_ start: Int) -> Bool {
            let end = min(start + win, samples.count)
            guard end > start else { return false }
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(end - start)).squareRoot() > threshold
        }
        var first = 0
        while first < samples.count, !loud(first) { first += win }
        guard first < samples.count else { return self }   // all silence -> leave untouched
        var last = samples.count
        var j = samples.count - win
        while j > first { if loud(j) { last = min(samples.count, j + win); break }; j -= win }
        let pad = Int(sampleRate * padMs / 1000)
        let lo = max(0, first - pad), hi = min(samples.count, last + pad)
        guard lo < hi else { return self }
        return AudioSamples(samples: Array(samples[lo..<hi]), sampleRate: sampleRate)
    }

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
