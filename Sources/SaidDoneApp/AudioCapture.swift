import AVFoundation
import AudioToolbox
import SaidDoneCore

/// Captures mic audio for an arbitrary duration, stops only on command (ADR-0006: no silence auto-stop).
/// Resamples to 16 kHz mono Float for the ASR Provider.
final class AudioCapture: @unchecked Sendable {
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
    private var configObserver: NSObjectProtocol?

    /// Called on the audio thread with the current RMS level (0…~1) for live UI feedback.
    var onLevel: (@Sendable (Float) -> Void)?

    /// Capture from the built-in mic instead of the system-default input. Keeps a Bluetooth headset
    /// (AirPods) on hi-fi A2DP — opening its mic would force narrowband HFP and muffle playback.
    var preferBuiltInMic = false

    func start() throws {
        tearDownEngine()
        lock.withLock { collected.removeAll(keepingCapacity: true) }

        let engine = AVAudioEngine()
        self.engine = engine
        try installTap(on: engine)
        engine.prepare()
        try engine.start()
        isRecording = true

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartTapAfterRouteChange()
        }
    }

    func snapshot() -> AudioSamples {
        AudioSamples(samples: lock.withLock { collected })
    }

    /// Stop and return everything captured as 16 kHz mono. Fully releases the engine.
    func stop() -> AudioSamples {
        let samples = lock.withLock { collected }
        tearDownEngine()
        return AudioSamples(samples: samples)
    }

    // MARK: - Internals

    private func installTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        if preferBuiltInMic, let builtIn = AudioDevices.builtInInputDeviceID(), let unit = input.audioUnit {
            var dev = builtIn
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err != noErr { slog("audio: built-in mic pin failed (\(err))") }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.invalidInputFormat
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
    }

    /// Input route/format changed (Bluetooth connect, etc.) — re-open the tap or capture goes silent.
    private func restartTapAfterRouteChange() {
        guard isRecording, let engine else { return }
        slog("audio: route changed — restarting input tap")
        do {
            try installTap(on: engine)
            if !engine.isRunning { try engine.start() }
        } catch {
            slog("audio: tap restart failed: \(error)")
        }
    }

    private func tearDownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        engine = nil
        converter = nil
        isRecording = false
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
        guard frames > 0 else { return }
        let slice = Array(UnsafeBufferPointer(start: ch[0], count: frames))
        lock.withLock { collected.append(contentsOf: slice) }

        if let onLevel {
            var sum: Float = 0
            for v in slice { sum += v * v }
            onLevel(min(1, sqrt(sum / Float(frames)) * 4))
        }
    }
}

enum CaptureError: Error {
    case invalidInputFormat
}
