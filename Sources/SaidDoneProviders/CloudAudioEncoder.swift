import Foundation
import SaidDoneCore

/// Compresses captured audio for cloud ASR upload. AAC/M4A is ~8× smaller than 16 kHz WAV;
/// Groq/OpenAI accept m4a and end-to-end latency drops sharply on longer clips (less upload time).
enum CloudAudioEncoder {
    struct UploadPayload: Sendable {
        let data: Data
        let filename: String
        let mimeType: String
    }

    /// Prefer AAC/M4A via `afconvert`; fall back to WAV if encoding fails.
    static func uploadPayload(from audio: AudioSamples) -> UploadPayload {
        if let m4a = try? m4aData(from: audio), m4a.count > 44 {
            return UploadPayload(data: m4a, filename: "audio.m4a", mimeType: "audio/mp4")
        }
        return UploadPayload(data: audio.wavData(), filename: "audio.wav", mimeType: "audio/wav")
    }

    /// Encode to AAC in an M4A container using the system `afconvert` tool (Groq-compatible).
    static func m4aData(from audio: AudioSamples, bitRate: Int = 32_000) throws -> Data {
        guard !audio.samples.isEmpty else { throw EncodeError.empty }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let wav = dir.appendingPathComponent("saiddone-\(UUID().uuidString).wav")
        let m4a = dir.appendingPathComponent("saiddone-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: m4a)
        }
        try audio.wavData().write(to: wav)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        proc.arguments = ["-d", "aac", "-f", "m4af", "-b", "\(bitRate)", wav.path, m4a.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw EncodeError.conversionFailed }
        let data = try Data(contentsOf: m4a)
        guard data.count > 44 else { throw EncodeError.conversionFailed }
        return data
    }

    enum EncodeError: Error { case empty, conversionFailed }
}
