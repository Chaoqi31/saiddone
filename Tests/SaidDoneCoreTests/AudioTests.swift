import XCTest
@testable import SaidDoneCore

final class AudioTests: XCTestCase {
    func testWavDataHeaderAndSize() {
        let a = AudioSamples(samples: [0, 0.5, -0.5, 1, -1], sampleRate: 16000)
        let d = a.wavData()
        XCTAssertEqual(d.count, 44 + 5 * 2)  // 44-byte header + 5 × Int16
        XCTAssertEqual(String(data: d.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: d.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: d.subdata(in: 36..<40), encoding: .ascii), "data")
    }

    func testDurationAndShortFlag() {
        XCTAssertEqual(AudioSamples(samples: [Float](repeating: 0, count: 16000)).duration, 1, accuracy: 0.001)
        XCTAssertTrue(AudioSamples(samples: [Float](repeating: 0, count: 16000 * 10)).isShortUtterance)
        XCTAssertFalse(AudioSamples(samples: [Float](repeating: 0, count: 16000 * 20)).isShortUtterance)
    }

    func testTrimsLeadingTrailingSilence() {
        var s = [Float](repeating: 0, count: 16_000)      // 1s silence
        s += [Float](repeating: 0.5, count: 8_000)        // 0.5s speech
        s += [Float](repeating: 0, count: 16_000)         // 1s silence
        let trimmed = AudioSamples(samples: s, sampleRate: 16_000).trimmedSilence()
        XCTAssertLessThan(trimmed.duration, 1.0)
        XCTAssertGreaterThan(trimmed.duration, 0.4)
    }

    func testAllSilenceUntouched() {
        let a = AudioSamples(samples: [Float](repeating: 0, count: 1000), sampleRate: 16_000)
        XCTAssertEqual(a.trimmedSilence().samples.count, 1000)
    }
}
