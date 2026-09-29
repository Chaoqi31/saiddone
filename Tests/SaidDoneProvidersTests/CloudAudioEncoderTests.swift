import Foundation
import Testing
@testable import SaidDoneProviders
import SaidDoneCore

struct CloudAudioEncoderTests {
    @Test func m4aSmallerThanWavForSpeechLengthClip() throws {
        var samples = [Float](repeating: 0, count: 16_000 * 5)
        for i in 0..<samples.count {
            let t = Float(i) / 16_000
            samples[i] = 0.08 * sin(2 * Float.pi * 220 * t)
        }
        let audio = AudioSamples(samples: samples, sampleRate: 16_000)
        let wav = audio.wavData()
        let m4a = try CloudAudioEncoder.m4aData(from: audio)
        #expect(m4a.count < (wav.count / 2))
        #expect(m4a.count > 100)
    }

    @Test func uploadPayloadPrefersM4a() {
        let audio = AudioSamples(samples: [Float](repeating: 0.05, count: 16_000), sampleRate: 16_000)
        let payload = CloudAudioEncoder.uploadPayload(from: audio)
        #expect(payload.filename == "audio.m4a")
        #expect(payload.mimeType == "audio/mp4")
        #expect(payload.data.count < (audio.wavData().count))
    }
}
