import XCTest
@testable import SaidDoneProviders
import SaidDoneCore

final class CloudAudioEncoderTests: XCTestCase {
    func testM4aSmallerThanWavForSpeechLengthClip() throws {
        var samples = [Float](repeating: 0, count: 16_000 * 5)
        for i in 0..<samples.count {
            let t = Float(i) / 16_000
            samples[i] = 0.08 * sin(2 * Float.pi * 220 * t)
        }
        let audio = AudioSamples(samples: samples, sampleRate: 16_000)
        let wav = audio.wavData()
        let m4a = try CloudAudioEncoder.m4aData(from: audio)
        XCTAssertLessThan(m4a.count, wav.count / 2)
        XCTAssertGreaterThan(m4a.count, 100)
    }

    func testUploadPayloadPrefersM4a() {
        let audio = AudioSamples(samples: [Float](repeating: 0.05, count: 16_000), sampleRate: 16_000)
        let payload = CloudAudioEncoder.uploadPayload(from: audio)
        XCTAssertEqual(payload.filename, "audio.m4a")
        XCTAssertEqual(payload.mimeType, "audio/mp4")
        XCTAssertLessThan(payload.data.count, audio.wavData().count)
    }
}
