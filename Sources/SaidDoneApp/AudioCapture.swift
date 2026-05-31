import AVFoundation
import SaidDoneCore

/// Captures mic audio for an arbitrary duration, stops only on command (ADR-0006: no silence auto-stop).
/// Resamples to 16 kHz mono Float for the ASR Provider.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioSamples.targetSampleRate,
        channels: 1,
        interleaved: false
    )!
    private let lock = NSLock()
    private var collected: [Float] = []
    private(set) var isRecording = false

    /// Called on the audio thread with the current RMS level (0…~1) for live UI feedback.
    var onLevel: (@Sendable (Float) -> Void)?

    func start() throws {
        lock.withLock { collected.removeAll(keepingCapacity: true) }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Copy of audio captured so far, without stopping — for live streaming preview.
    func snapshot() -> AudioSamples {
        AudioSamples(samples: lock.withLock { collected })
    }

    /// Stop and return everything captured as 16 kHz mono.
    func stop() -> AudioSamples {
        guard isRecording else { return AudioSamples(samples: []) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        let samples = lock.withLock { collected }
        return AudioSamples(samples: samples)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData else { return }
        let frames = Int(out.frameLength)
        let slice = Array(UnsafeBufferPointer(start: ch[0], count: frames))
        lock.withLock { collected.append(contentsOf: slice) }

        if let onLevel, frames > 0 {
            var sum: Float = 0
            for v in slice { sum += v * v }
            onLevel(min(1, sqrt(sum / Float(frames)) * 4))  // RMS, scaled for display
        }
    }
}
