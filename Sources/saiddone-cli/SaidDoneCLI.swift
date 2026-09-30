import ArgumentParser
import Foundation
import os
import SaidDoneCore
import SaidDoneEngines

struct SaidDoneCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "saiddone-cli",
        abstract: "Run SaidDone's real engines and pipeline without the app.",
        discussion: """
        Speech engines: whisper[:turbo|compact|large], volcengine[:<app id>], <vendor>:<model>, <base URL>#<model>.
        AI engines: qwen[:4b|1.7b|8b], <vendor>:<model>, <base URL>#<model>.
        Keys come from SAIDDONE_KEY_<VENDOR> (for example SAIDDONE_KEY_DEEPSEEK), or SAIDDONE_KEY.
        """,
        subcommands: [Run.self, Download.self, ListModels.self])
}

@main
enum Entry {
    static func main() async {
        // Progress lines interleave with errors on stderr in the order they happen.
        setvbuf(stdout, nil, _IOLBF, 0)
        await SaidDoneCLI.main()
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe and process an audio file.")

    @Argument(help: "Any audio file AVFoundation reads.") var audio: String
    @Option(help: "dictate, translate:<language>, or ask.") var mode = "dictate"
    @Option(help: "Selected text for ask.") var selection = ""
    @Option(help: "Spoken language code, or auto.") var language = "zh"
    @Option var speech = "whisper"
    @Option var ai = "deepseek:deepseek-flash"
    @Option(help: "host:port") var proxy: String?
    @Option(help: "Dictionary terms: Term or Term=misheard|misheard, comma separated.") var terms = ""

    func run() async throws {
        let samples = try AudioCodec.read(URL(fileURLWithPath: audio))
        let proxy = try proxy.map(parseProxy)
        let speechEngine = try parseSpeech(speech)
        let aiEngine = try parseAI(ai)
        let setup = EngineSetup(speech: SpeechSetup(speechEngine, key: key(speechEngine.vendor), proxy: proxy),
                                ai: AISetup(aiEngine, key: key(aiEngine.vendor), proxy: proxy))
        var lexicon = Lexicon()
        for entry in terms.split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            lexicon.add(String(parts[0]), misheard: parts.count > 1 ? parts[1].split(separator: "|").map(String.init) : [],
                        at: .now)
        }
        let context = JobContext(language: language == "auto" ? nil : Language(rawValue: language), lexicon: lexicon)

        let engines = Engines()
        let clock = ContinuousClock()
        let loadStart = clock.now
        try await engines.prepare(setup)
        print("loaded in \(loadStart.duration(to: clock.now))")
        let pipeline = await engines.pipeline(for: setup)
        let runStart = clock.now
        let result = try await pipeline.run(samples, try parseRequest(), context,
                                            budget: Budget.ai(local: aiEngine.isLocal, audio: samples.length)) {
            print("stage: \($0.rawValue) at \(runStart.duration(to: clock.now))")
        }
        print("audio: \(samples.length)")
        print("transcript: \(result.transcript)")
        print("output: \(result.output)")
        print("elapsed: \(result.elapsed)")
    }

    private func parseRequest() throws -> Request {
        if mode == "dictate" { return .dictate }
        if mode == "ask" { return .ask(selection: selection) }
        if mode.hasPrefix("translate:") { return .translate(to: Language(rawValue: String(mode.dropFirst(10)))) }
        throw ValidationError("Unknown mode \(mode)")
    }
}

struct Download: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download an on-device model into the app's model folder.")

    @Argument(help: "whisper[:turbo|compact|large] or qwen[:4b|1.7b|8b]") var model: String
    @Flag(help: "Download through hf-mirror.com.") var mirror = false

    func run() async throws {
        let local: LocalModel
        if model.hasPrefix("whisper"), case let .whisper(whisper) = try parseSpeech(model) {
            local = .whisper(whisper)
        } else if case let .qwen(qwen) = try parseAI(model) {
            local = .qwen(qwen)
        } else {
            throw ValidationError("Not an on-device model: \(model)")
        }
        let shown = OSAllocatedUnfairLock(initialState: -1)
        try await ModelFiles.standard.download(local, mirror: mirror) { fraction in
            let percent = Int(fraction * 100)
            if shown.withLock({ last in defer { last = percent }; return percent > last }) { print("\(percent)%") }
        }
        print("installed \(local.name)")
    }
}

struct ListModels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "models", abstract: "List an endpoint's models.")

    @Argument(help: "A preset vendor (deepseek, openai, …) or a base URL.") var endpoint: String
    @Option(help: "host:port") var proxy: String?

    func run() async throws {
        let endpoint = try parseEndpoint(self.endpoint + "#", presets: CloudPreset.chat + CloudPreset.speech)
        for name in try await Engines().models(at: endpoint, key: key(endpoint.vendor), proxy: try proxy.map(parseProxy)) {
            print(name)
        }
    }
}

// MARK: - Parsing

private func parseSpeech(_ spec: String) throws -> SpeechEngine {
    let (name, argument) = split(spec)
    switch name {
    case "whisper":
        switch argument ?? "turbo" {
        case "turbo": return .whisper(.largeV3Turbo)
        case "compact": return .whisper(.largeV3TurboCompact)
        case "large": return .whisper(.largeV3)
        case let other: throw ValidationError("Unknown Whisper model \(other)")
        }
    case "volcengine":
        return .volcengine(appID: argument ?? "")
    default:
        return .cloud(try parseEndpoint(spec, presets: CloudPreset.speech))
    }
}

private func parseAI(_ spec: String) throws -> AIEngine {
    let (name, argument) = split(spec)
    guard name == "qwen" else { return .cloud(try parseEndpoint(spec, presets: CloudPreset.chat)) }
    switch argument ?? "4b" {
    case "4b": return .qwen(.qwen3_4B)
    case "1.7b": return .qwen(.qwen3_1_7B)
    case "8b": return .qwen(.qwen3_8B)
    case let other: throw ValidationError("Unknown Qwen model \(other)")
    }
}

/// `<vendor>:<model>` for a preset, `<base URL>#<model>` for anything else.
private func parseEndpoint(_ spec: String, presets: [CloudPreset]) throws -> CloudEndpoint {
    if spec.hasPrefix("http"), let hash = spec.lastIndex(of: "#"), let url = URL(string: String(spec[..<hash])) {
        return CloudEndpoint(vendor: .customChat, baseURL: url, model: String(spec[spec.index(after: hash)...]))
    }
    let (vendor, model) = split(spec.replacingOccurrences(of: "#", with: ""))
    guard let preset = presets.first(where: { $0.id.rawValue == vendor }) else {
        throw ValidationError("Unknown vendor \(vendor). Known: \(presets.map(\.id.rawValue).joined(separator: ", "))")
    }
    return CloudEndpoint(vendor: preset.id, baseURL: preset.baseURL, model: model ?? preset.models.first ?? "")
}

private func parseProxy(_ spec: String) throws -> Proxy {
    let parts = spec.split(separator: ":")
    guard parts.count == 2, let port = Int(parts[1]) else { throw ValidationError("Proxy must be host:port") }
    return Proxy(host: String(parts[0]), port: port)
}

private func split(_ spec: String) -> (String, String?) {
    guard let colon = spec.firstIndex(of: ":") else { return (spec, nil) }
    return (String(spec[..<colon]), String(spec[spec.index(after: colon)...]))
}

private func key(_ vendor: VendorID?) -> String {
    guard let vendor else { return "" }
    let environment = ProcessInfo.processInfo.environment
    let name = "SAIDDONE_KEY_" + vendor.rawValue.uppercased().replacingOccurrences(of: "-", with: "_")
    return environment[name] ?? environment["SAIDDONE_KEY"] ?? ""
}
