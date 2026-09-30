import AVFoundation
import CoreAudio
import Observation
import SaidDoneCore
import SaidDoneEngines

enum CaptureError: Error, Equatable {
    case notAuthorized
    case noInputDevice
    case engineFailed
}

/// Microphone capture at 16 kHz mono, the input device list, and the live level for the voice bar and the settings
/// meter. Stops only when told to: there is no silence auto-stop.
@MainActor @Observable
final class Recorder {
    private(set) var devices: [InputDevice] = []
    private(set) var systemDefault: String?
    /// Recent input levels, 0…1, newest last. The voice bar draws them as bars.
    private(set) var levels: [Float] = Array(repeating: 0, count: 32)
    private(set) var isRecording = false
    private(set) var isMetering = false

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var capture: Capture?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    init() {
        refreshDevices()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let refresh: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshDevices() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, refresh)
        address.mSelector = kAudioHardwarePropertyDefaultInputDevice
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, refresh)
    }

    /// Starts recording from the chosen microphone. Returns whether the choice had to be substituted because the
    /// chosen device is not connected.
    @discardableResult
    func start(_ choice: MicrophoneChoice) throws(CaptureError) -> Bool {
        stopEngine()
        let resolution = choice.resolve(devices, systemDefault: systemDefault)
        try startEngine(device: resolution.uid, keep: true)
        isRecording = true
        return resolution.substituted
    }

    func stop() -> AudioSamples {
        let samples = capture?.take() ?? []
        stopEngine()
        return AudioSamples(samples: samples)
    }

    func discard() { stopEngine() }

    /// The settings meter: levels without keeping audio. A recording takes over the microphone.
    func startMeter(_ choice: MicrophoneChoice) {
        guard !isRecording else { return }
        stopEngine()
        try? startEngine(device: choice.resolve(devices, systemDefault: systemDefault).uid, keep: false)
        isMetering = engine != nil
    }

    func stopMeter() {
        guard isMetering else { return }
        stopEngine()
    }

    // MARK: - Engine

    private func startEngine(device: String?, keep: Bool) throws(CaptureError) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw .notAuthorized }
        let engine = AVAudioEngine()
        if let device, let id = Self.deviceID(uid: device), let unit = engine.inputNode.audioUnit {
            var id = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { log.error("recorder: pinning the input device failed (\(status))") }
        }
        let capture = Capture(keep: keep) { [weak self] level in
            Task { @MainActor in self?.push(level) }
        }
        do {
            try install(capture, on: engine)
            engine.prepare()
            try engine.start()
        } catch let error as CaptureError {
            throw error
        } catch {
            log.error("recorder: start failed: \(error.localizedDescription, privacy: .public)")
            throw .engineFailed
        }
        self.engine = engine
        self.capture = capture
        levels = Array(repeating: 0, count: levels.count)
        // A route change (headset connected, sample rate switched) stops the tap; reinstall it so capture continues.
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterRouteChange() }
        }
    }

    private func install(_ capture: Capture, on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        capture.reset(format: format)
        input.removeTap(onBus: 0)
        // About 40 ms per buffer at 48 kHz: the meter follows syllables, not stale peaks.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in capture.append(buffer) }
    }

    private func restartAfterRouteChange() {
        guard let engine, let capture else { return }
        do {
            try install(capture, on: engine)
            if !engine.isRunning { try engine.start() }
        } catch {
            log.error("recorder: restart after route change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopEngine() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        capture = nil
        isRecording = false
        isMetering = false
        levels = Array(repeating: 0, count: levels.count)
    }

    private func push(_ level: Float) {
        guard engine != nil else { return }
        levels.removeFirst()
        levels.append(level)
    }

    // MARK: - Devices

    private func refreshDevices() {
        devices = Self.inputDevices()
        systemDefault = Self.defaultInputUID()
    }

    private static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport: InputDevice.Transport = switch uint32(id, kAudioDevicePropertyTransportType) {
            case kAudioDeviceTransportTypeBuiltIn: .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
            case kAudioDeviceTransportTypeUSB: .usb
            default: .other
            }
            return InputDevice(id: uid, name: name, transport: transport)
        }
    }

    private static func defaultInputUID() -> String? {
        let device = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return device == 0 ? nil : string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
}

/// The audio thread's side of a recording: resampling, accumulation and the level envelope.
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private let keep: Bool
    private let onLevel: @Sendable (Float) -> Void
    private var resampler: Resampler?
    private var samples: [Float] = []
    private var envelope: Float = 0

    init(keep: Bool, onLevel: @escaping @Sendable (Float) -> Void) {
        self.keep = keep
        self.onLevel = onLevel
    }

    func reset(format: AVAudioFormat) {
        lock.withLock { resampler = Resampler(from: format) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let level: Float? = lock.withLock {
            guard let chunk = resampler?.convert(buffer), !chunk.isEmpty else { return nil }
            if keep { samples.append(contentsOf: chunk) }
            // Instant attack, ~180 ms release: bars rise with speech and hold between syllables.
            let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
            let seconds = Float(chunk.count) / Float(AudioSamples.targetSampleRate)
            envelope += (rms - envelope) * (rms > envelope ? 1 : 1 - expf(-seconds / 0.18))
            return min(1, (envelope * 6).squareRoot())
        }
        if let level { onLevel(level) }
    }

    func take() -> [Float] { lock.withLock { samples } }
}
