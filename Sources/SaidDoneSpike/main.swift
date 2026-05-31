import Foundation
import AVFoundation
import MLX
import SaidDoneCore
import SaidDoneProviders

setvbuf(stdout, nil, _IONBF, 0)  // unbuffered so output survives a native crash
// swift build CLI doesn't compile MLX's metallib -> force CPU backend so we can verify correctness.
if ProcessInfo.processInfo.environment["MLX_FORCE_CPU"] == "1" {
    Device.setDefault(device: Device(.cpu))
}

// Usage: SaidDoneSpike <audiofile> [dictate|translate] [targetLang]
// Loads audio → 16k mono → runs the local ASR ladder + LLM, prints raw/final + timing.

func loadAudio(_ path: String) throws -> AudioSamples {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: AudioSamples.targetSampleRate,
                               channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let cap = AVAudioFrameCount(file.length)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) else {
        throw NSError(domain: "spike", code: 1)
    }
    try file.read(into: input)
    let ratio = target.sampleRate / file.processingFormat.sampleRate
    let outCap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else {
        throw NSError(domain: "spike", code: 2)
    }
    var fed = false
    var err: NSError?
    converter.convert(to: out, error: &err) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return input
    }
    if let err { throw err }
    let n = Int(out.frameLength)
    let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
    return AudioSamples(samples: samples)
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: SaidDoneSpike <audio> [dictate|translate] [lang]"); exit(2) }
let path = args[1]
let modeArg = args.count >= 3 ? args[2] : "dictate"
let lang = args.count >= 4 ? args[3] : "en"

do {
    let audio = try loadAudio(path)
    print("audio: \(String(format: "%.2f", audio.duration))s, \(audio.samples.count) samples @16k")

    var cfg = AppConfig.default
    if let m = ProcessInfo.processInfo.environment["SAIDDONE_LLM"] { cfg.llm.modelID = m }  // e.g. mlx-community/Qwen3-1.7B-4bit
    let asr = ProviderFactory.makeASR(cfg)   // ladder: MLX-ASR(scaffold)→0.6B(scaffold)→WhisperKit
    let llm = ProviderFactory.makeLLM(cfg)   // RuleBased, or MLX-Qwen if SAIDDONE_LLM set
    let orch = PipelineOrchestrator(asr: asr, llm: llm)
    let mode: Mode = modeArg == "translate" ? .translation(target: lang) : .dictation

    // Cold run = includes one-time model load/compile (in the app this happens once at startup).
    let cold0 = Date()
    let result = try await orch.run(audio, mode: mode)
    let coldDt = Date().timeIntervalSince(cold0)

    // Warm run = real per-utterance latency the user feels (model already resident). This is the B1 number.
    let warm0 = Date()
    let warm = try await orch.run(audio, mode: mode)
    let warmDt = Date().timeIntervalSince(warm0)

    print("--- RAW ASR ---\n\(result.rawTranscript)")
    print("--- FINAL (\(modeArg)) ---\n\(result.text)")
    print("--- cold (incl. model load): \(String(format: "%.2f", coldDt))s ---")
    print("--- warm (per-utterance, B1): \(String(format: "%.2f", warmDt))s ---")
    print(warmDt <= 2 ? "B1 ≤2s: PASS" : "B1 ≤2s: OVER (\(String(format: "%.2f", warmDt))s)")
    _ = warm
} catch {
    print("ERROR: \(error)")
    exit(1)
}
