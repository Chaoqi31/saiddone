import Foundation
import Testing
@testable import SaidDoneCore

struct AudioTests {
    @Test func wavDataHeaderAndSize() {
        let a = AudioSamples(samples: [0, 0.5, -0.5, 1, -1], sampleRate: 16000)
        let d = a.wavData()
        #expect(d.count == (44 + 5 * 2))  // 44-byte header + 5 × Int16
        #expect((String(data: d.prefix(4), encoding: .ascii)) == "RIFF")
        #expect((String(data: d.subdata(in: 8..<12), encoding: .ascii)) == "WAVE")
        #expect((String(data: d.subdata(in: 36..<40), encoding: .ascii)) == "data")
    }

    @Test func durationAndSilence() {
        #expect(abs(AudioSamples(samples: [Float](repeating: 0, count: 16000)).duration - 1) < 0.001)
        #expect(AudioSamples(samples: [Float](repeating: 0, count: 16000)).isEffectivelySilent, "digital silence")
        #expect(AudioSamples(samples: [Float](repeating: 0.3, count: 1600)).isEffectivelySilent, "0.1 s tap")
        #expect(!AudioSamples(samples: [Float](repeating: 0.3, count: 8000)).isEffectivelySilent)
    }

    @Test func trimsLeadingTrailingSilence() {
        var s = [Float](repeating: 0, count: 16_000)      // 1s silence
        s += [Float](repeating: 0.5, count: 8_000)        // 0.5s speech
        s += [Float](repeating: 0, count: 16_000)         // 1s silence
        let trimmed = AudioSamples(samples: s, sampleRate: 16_000).trimmedSilence()
        #expect(trimmed.duration < 1.0)
        #expect(trimmed.duration > 0.4)
    }

    @Test func allSilenceUntouched() {
        let a = AudioSamples(samples: [Float](repeating: 0, count: 1000), sampleRate: 16_000)
        #expect((a.trimmedSilence().samples.count) == 1000)
    }

    @Test func peakRMSUsesWindowedMaxNotWholeBufferAverage() {
        var s = [Float](repeating: 0, count: 16_000)      // 1s silence
        s += [Float](repeating: 0.05, count: 800)         // 50ms quiet speech
        s += [Float](repeating: 0, count: 16_000)
        let peak = AudioSamples(samples: s, sampleRate: 16_000).peakRMS
        #expect(peak > 0.04)
        #expect(peak < 0.06)
    }
}
