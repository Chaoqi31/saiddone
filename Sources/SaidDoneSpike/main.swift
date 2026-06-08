import Foundation
import AVFoundation
import MLX
import SaidDoneCore
import SaidDoneProviders

setvbuf(stdout, nil, _IONBF, 0)
if ProcessInfo.processInfo.environment["MLX_FORCE_CPU"] == "1" { Device.setDefault(device: Device(.cpu)) }

// Each arg = "path|mode|lang" (mode: dictate|translate). Providers loaded once, then all clips run.
func loadAudio(_ path: String) throws -> AudioSamples {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: AudioSamples.targetSampleRate, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "spike", code: 1)
    }
    try file.read(into: input)
    let outCap = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 4096
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { throw NSError(domain: "spike", code: 2) }
    var fed = false; var err: NSError?
    converter.convert(to: out, error: &err) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return input
    }
    if let err { throw err }
    let n = Int(out.frameLength)
    return AudioSamples(samples: Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: n)))
}

let specs = Array(CommandLine.arguments.dropFirst())
guard !specs.isEmpty else { print("usage: SaidDoneSpike 'path|mode|lang' ..."); exit(2) }

// Load the REAL app config (same config.json the app uses) so the spike exercises the live
// provider setup — including cloud DeepSeek when the app is set to cloud.
let cfgDir = (try? ConfigStore.defaultDirectory()) ?? FileManager.default.temporaryDirectory
var cfg = ConfigStore(directory: cfgDir).load()
if let m = ProcessInfo.processInfo.environment["SAIDDONE_LLM"] { cfg.llm.modelID = m }
if let l = ProcessInfo.processInfo.environment["SAIDDONE_ASR_LANG"] { cfg.asrLanguage = (l == "auto") ? nil : l }
let orch = PipelineOrchestrator(asr: ProviderFactory.makeASR(cfg), llm: ProviderFactory.makeLLM(cfg))

for spec in specs {
    let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    let path = parts[0]
    let modeStr = parts.count > 1 ? parts[1] : "dictate"
    let lang = parts.count > 2 ? parts[2] : "en"
    let mode: Mode = modeStr == "translate" ? .translation(target: lang) : .dictation
    do {
        let audio = try loadAudio(path)
        let t0 = Date()
        let r = try await orch.run(audio, mode: mode, languageHint: cfg.asrLanguage)
        let dt = Date().timeIntervalSince(t0)
        let name = (path as NSString).lastPathComponent
        print("### \(name)  [\(modeStr)\(modeStr == "translate" ? "->\(lang)" : "")]  \(String(format: "%.1f", audio.duration))s audio  \(String(format: "%.2f", dt))s pipe")
        print("RAW:   \(r.rawTranscript)")
        print("FINAL: \(r.text)\n")
    } catch {
        print("### \(path): ERROR \(error)\n")
    }
}
