import AVFoundation
import AudioToolbox
import SaidDoneCore

/// Captures mic audio for an arbitrary duration, stops only on command (ADR-0006: no silence auto-stop).
/// Resamples to 16 kHz mono Float for the ASR Provider.
final class AudioCapture: @unchecked Sendable {
    /// Recreated per recording and released on stop(), so the HAL input device is fully closed —
    /// otherwise a reused engine keeps the Bluetooth SCO/HFP link open and AirPods stay muffled
    /// (stuck in narrowband) even after dictation ends.
    private var engine: AVAudioEngine?
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

    /// Capture from the built-in mic instead of the system-default input. Keeps a Bluetooth headset
    /// (AirPods) on hi-fi A2DP — opening its mic would force narrowband HFP and muffle playback.
    var preferBuiltInMic = false

    func start() throws {
        lock.withLock { collected.removeAll(keepingCapacity: true) }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // Pin the engine's input to the built-in mic *before* the stream opens, so no input stream is
        // ever opened on the Bluetooth device (which is what triggers the A2DP→HFP downgrade).
        if preferBuiltInMic, let builtIn = AudioDevices.builtInInputDeviceID(), let unit = input.audioUnit {
            var dev = builtIn
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
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

    /// Stop and return everything captured as 16 kHz mono. Fully releases the engine so the input
    /// device (and any Bluetooth HFP link) is closed — AirPods return to hi-fi A2DP immediately.
    func stop() -> AudioSamples {
        guard isRecording, let engine else { return AudioSamples(samples: []) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
        converter = nil
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
