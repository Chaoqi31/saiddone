import AVFoundation
import Foundation
import SaidDoneCore
import Testing
@testable import SaidDoneEngines

private func tone(seconds: Double, rate: Double = 16_000) -> AudioSamples {
    AudioSamples(samples: (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * 440 / rate) * 0.5) },
                 sampleRate: rate)
}

private func rms(_ samples: [Float]) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "SaidDoneTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct AudioCodecTests {
    @Test func m4aIsSmallAndRoundTrips() throws {
        let audio = tone(seconds: 10)
        let data = try AudioCodec.m4a(audio)
        #expect(data.count < audio.wavData().count / 4)

        let url = try temporaryDirectory().appending(path: "a.m4a")
        try data.write(to: url)
        let decoded = try AudioCodec.read(url)
        #expect(abs(decoded.duration - 10) < 0.1)
        #expect(abs(rms(decoded.samples) - rms(audio.samples)) < 0.05)
    }

    @Test func readsAnyRateAndLayoutAs16kMono() throws {
        let url = try temporaryDirectory().appending(path: "stereo.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        let source = tone(seconds: 1, rate: 44_100).samples
        for channel in 0..<2 { source.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: 44_100) } }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let decoded = try AudioCodec.read(url)
        #expect(decoded.sampleRate == 16_000)
        #expect(abs(decoded.duration - 1) < 0.05)
        #expect(rms(decoded.samples) > 0.3)
    }
}

struct EnginesTests {
    private func setup(_ speech: SpeechEngine, _ ai: AIEngine, key: String = "k1") -> EngineSetup {
        EngineSetup(speech: SpeechSetup(speech, key: key, proxy: nil), ai: AISetup(ai, key: key, proxy: nil))
    }

    private let deepseek = AIEngine.cloud(CloudPreset.deepseek.defaultEndpoint)

    @Test func eachHalfStaysWarmUntilItsOwnInputsChange() async throws {
        let engines = Engines(files: ModelFiles(root: try temporaryDirectory()))
        let first = await engines.pipeline(for: setup(.whisper(.largeV3Turbo), deepseek, key: "k1"))
        let newKey = await engines.pipeline(for: setup(.whisper(.largeV3Turbo), deepseek, key: "k2"))
        #expect(first.transcriber as AnyObject === newKey.transcriber as AnyObject, "a new AI key keeps the speech model")
        #expect(first.chat as AnyObject !== newKey.chat as AnyObject)

        let newSpeech = await engines.pipeline(for: setup(.whisper(.largeV3TurboCompact), deepseek, key: "k2"))
        #expect(newKey.chat as AnyObject === newSpeech.chat as AnyObject)
        #expect(newKey.transcriber as AnyObject !== newSpeech.transcriber as AnyObject)
    }

    @Test func localSetupsIgnoreKeysAndProxies() {
        let proxy = Proxy(host: "127.0.0.1", port: 7890)
        #expect(SpeechSetup(.whisper(.largeV3), key: "x", proxy: proxy) == SpeechSetup(.whisper(.largeV3), key: "", proxy: nil))
        #expect(AISetup(.qwen(.qwen3_4B), key: "x", proxy: proxy) == AISetup(.qwen(.qwen3_4B), key: "", proxy: nil))
        #expect(AISetup(deepseek, key: "x", proxy: proxy) != AISetup(deepseek, key: "", proxy: nil))
    }

    @Test func setupsTakeEachHalfsOwnKey() {
        var prefs = Preferences()
        prefs.speech = .volcengine(appID: "")
        let setup = EngineSetup(prefs) { $0 == .volcengine ? "volc" : $0 == "deepseek" ? "ds" : "" }
        #expect(setup.speech.key == "volc")
        #expect(setup.ai.key == "ds")
    }

    @Test func missingLocalModelsFailPreparation() async throws {
        let engines = Engines(files: ModelFiles(root: try temporaryDirectory()))
        #expect(await failure { try await engines.prepare(setup(.whisper(.largeV3Turbo), deepseek)) } == .modelMissing)
        // A SwiftPM test build has no MLX shaders, so it must refuse before touching MLX, which would abort.
        #expect(await failure { try await engines.test(AISetup(.qwen(.qwen3_4B), key: "", proxy: nil)) }
                == (Engines.canRunOnDeviceAI ? .modelMissing : .unsupported))
    }

    @Test func testingACloudHalfSendsARealRequest() async throws {
        let server = StubServer { received in
            received.request.value(forHTTPHeaderField: "Authorization") == "Bearer good"
                ? .json(["choices": [["message": ["content": "OK"]]]]) : .http(401)
        }
        let engines = Engines(files: ModelFiles(root: try temporaryDirectory()), makeSession: { _ in server.session })
        let endpoint = CloudEndpoint(vendor: "deepseek", baseURL: server.baseURL, model: "deepseek-flash")
        #expect(await failure { try await engines.test(AISetup(.cloud(endpoint), key: "good", proxy: nil)) } == nil)
        #expect(await failure { try await engines.test(AISetup(.cloud(endpoint), key: "bad", proxy: nil)) } == .unauthorized)
    }
}

struct ModelFilesTests {
    @Test func aModelIsInstalledOnlyOnceMarkedComplete() throws {
        let files = ModelFiles(root: try temporaryDirectory())
        let model = LocalModel.whisper(.largeV3Turbo)
        try FileManager.default.createDirectory(at: files.folder(model), withIntermediateDirectories: true)
        #expect(files.installed().isEmpty, "a partial download is not installed")
        try Data().write(to: files.folder(model).appending(path: ".saiddone-complete"))
        #expect(files.installed() == [model])
        try files.remove(model)
        #expect(files.installed().isEmpty)
        try files.remove(model)
    }

    @Test func foldersFollowTheHubLayout() {
        let files = ModelFiles(root: URL(filePath: "/m"))
        #expect(files.folder(.whisper(.largeV3Turbo)).path
                == "/m/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo")
        #expect(files.folder(.qwen(.qwen3_4B)).path == "/m/models/mlx-community/Qwen3-4B-Instruct-2507-4bit")
    }
}
