import AVFoundation
import SaidDoneCore

public enum AudioCodec {
    public enum Failure: Error { case unreadable, encoderUnavailable }

    /// AAC in an M4A container at the recording's rate, about 32 kbps: an eighth the size of 16-bit WAV.
    public static func m4a(_ audio: AudioSamples) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "SaidDone-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(audio, to: url)
        return try Data(contentsOf: url)
    }

    public static func write(_ audio: AudioSamples, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, audio.samples.count)))
        else { throw Failure.encoderUnavailable }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        // The file is finalized when it is released at the end of this scope.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Any file AVFoundation can read (m4a, wav, aiff, mp3), as 16 kHz mono.
    public static func read(_ url: URL) throws -> AudioSamples {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return AudioSamples(samples: []) }
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let resampler = Resampler(from: file.processingFormat)
        else { throw Failure.unreadable }
        try file.read(into: input)
        return AudioSamples(samples: resampler.convert(input, last: true))
    }
}

/// Converts PCM buffers of any rate and channel layout to 16 kHz mono float samples, one buffer at a time.
public final class Resampler {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    public init?(from source: AVAudioFormat) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioSamples.targetSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target)
        else { return nil }
        converter.downmix = true
        self.converter = converter
        self.target = target
    }

    /// `last` flushes the converter; the resampler is spent afterwards.
    public func convert(_ buffer: AVAudioPCMBuffer, last: Bool = false) -> [Float] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024)
        else { return [] }
        let pending = Pending(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard let next = pending.take() else {
                state.pointee = last ? .endOfStream : .noDataNow
                return nil
            }
            state.pointee = .haveData
            return next
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Hands the converter its input once. The converter calls its input block synchronously inside `convert`, so the
    /// buffer is never actually shared across threads.
    private final class Pending: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}
