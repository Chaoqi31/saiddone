import Foundation
import Testing
@testable import SaidDoneCore

struct PreferencesTests {
    @Test func roundTrips() throws {
        var prefs = Preferences()
        prefs.spokenLanguage = .detect
        prefs.speech = .volcengine(appID: "123")
        prefs.ai = .qwen(.qwen3_8B)
        prefs.proxy = Proxy(host: "127.0.0.1", port: 7890)
        prefs.personalization.toneByApp["com.tinyspeck.slackmacgap"] = "casual"
        #expect(Preferences.decode(try JSONEncoder().encode(prefs)) == prefs)
    }

    @Test func aBadOrUnknownKeyResetsOnlyItself() {
        let json = #"""
        {"sounds": false, "speech": {"nonsense": 1}, "translationTarget": "ja", "futureSetting": [1, 2]}
        """#
        let prefs = Preferences.decode(Data(json.utf8))
        #expect(prefs.sounds == false)
        #expect(prefs.translationTarget == "ja")
        #expect(prefs.speech == Preferences().speech)
    }

    @Test func garbageYieldsDefaults() {
        #expect(Preferences.decode(Data("not json".utf8)) == Preferences())
        #expect(Preferences.decode(Data()) == Preferences())
    }

    @Test func autoDetectSurvivesAsAValue() throws {
        var prefs = Preferences()
        prefs.spokenLanguage = .detect
        let json = String(decoding: try JSONEncoder().encode(prefs), as: UTF8.self)
        #expect(json.contains(#""spokenLanguage":"auto""#))
        #expect(Preferences.decode(Data(json.utf8)).spokenLanguage.language == nil)
    }

    @Test func toneFallsBackToTheDefault() {
        let p = Personalization(defaultTone: "neutral", toneByApp: ["com.apple.mail": "formal", "x": "  "])
        #expect(p.tone(for: "com.apple.mail") == "formal")
        #expect(p.tone(for: "com.other") == "neutral")
        #expect(p.tone(for: "x") == nil)
        #expect(Personalization().tone(for: nil) == nil)
    }

    @Test func aNewInstallStartsFromTheSystemLanguageAndRegion() {
        let chinese = Preferences.firstRun(languages: ["zh-Hans-CN", "en-CN"], region: "CN")
        #expect(chinese.spokenLanguage == .fixed(.chinese))
        #expect(chinese.translationTarget == .english)
        #expect(chinese.downloadMirror)
        let american = Preferences.firstRun(languages: ["en-US"], region: "US")
        #expect(american.spokenLanguage == .fixed(.english))
        #expect(american.translationTarget == .chinese)
        #expect(!american.downloadMirror)
        #expect(Preferences.firstRun(languages: ["pt-BR"], region: "BR").spokenLanguage == .detect)
        #expect(Preferences.firstRun(languages: [], region: nil).spokenLanguage == .fixed(.english))
    }
}

struct MicrophoneChoiceTests {
    private let builtIn = InputDevice(id: "builtin", name: "MacBook Pro Microphone", transport: .builtIn)
    private let airPods = InputDevice(id: "airpods", name: "AirPods Pro", transport: .bluetooth)
    private let yeti = InputDevice(id: "yeti", name: "Blue Yeti", transport: .usb)

    @Test func automaticSkipsABluetoothDefault() {
        let devices = [builtIn, airPods, yeti]
        #expect(MicrophoneChoice.automatic.resolve(devices, systemDefault: "airpods").uid == "builtin")
        #expect(MicrophoneChoice.automatic.resolve(devices, systemDefault: "yeti").uid == nil)
        #expect(MicrophoneChoice.automatic.resolve([airPods], systemDefault: "airpods").uid == nil)
    }

    @Test func aMissingChosenDeviceFallsBackVisibly() {
        let choice = MicrophoneChoice.device(uid: "yeti", name: "Blue Yeti")
        #expect(choice.resolve([builtIn, yeti], systemDefault: "builtin") == .init(uid: "yeti", substituted: false))
        #expect(choice.resolve([builtIn, airPods], systemDefault: "airpods") == .init(uid: "builtin", substituted: true))
    }
}

struct ReadinessTests {
    private let allGood = SetupFacts(microphoneAllowed: true, accessibilityAllowed: true, globeKeyFree: true,
                                     installed: [.whisper(.recommended)], credentials: ["deepseek"], onDeviceAI: true)

    @Test func defaultsAreReadyWithAKeyAndTheModel() {
        #expect(Readiness.issues(Preferences(), allGood).isEmpty)
    }

    @Test func issuesComeInFixOrder() {
        let facts = SetupFacts(microphoneAllowed: false, accessibilityAllowed: false, globeKeyFree: false,
                               installed: [], credentials: [], onDeviceAI: true)
        #expect(Readiness.issues(Preferences(), facts) == [
            .microphoneNotAllowed, .accessibilityNotAllowed, .modelNotInstalled(.whisper(.recommended)),
            .credentialMissing("deepseek"), .globeKeyAssigned,
        ])
        #expect(Readiness.recordingBlocker(Preferences(), facts) == .microphoneNotAllowed)
    }

    @Test func onDeviceAIThisBuildCantRunIsReportedInsteadOfItsDownload() {
        var prefs = Preferences()
        prefs.ai = .qwen(.recommended)
        var facts = allGood
        #expect(Readiness.issues(prefs, facts) == [.modelNotInstalled(.qwen(.recommended))])
        facts.onDeviceAI = false
        #expect(Readiness.issues(prefs, facts) == [.onDeviceAIUnavailable])
        #expect(Readiness.recordingBlocker(prefs, facts) == .onDeviceAIUnavailable)
    }

    @Test func globeKeyWarnsButNeverBlocks() {
        var facts = allGood
        facts.globeKeyFree = false
        #expect(Readiness.issues(Preferences(), facts) == [.globeKeyAssigned])
        #expect(Readiness.recordingBlocker(Preferences(), facts) == nil)
        var prefs = Preferences()
        for trigger in prefs.shortcuts.owners.keys where trigger.usesFn { prefs.shortcuts.unbind(trigger) }
        #expect(Readiness.issues(prefs, facts).isEmpty)
    }

    @Test func oneKeyServesBothHalvesAndKeylessVendorsNeedNone() {
        var prefs = Preferences()
        prefs.speech = .cloud(CloudPreset.speech("openai")!.defaultEndpoint)
        prefs.ai = .cloud(CloudPreset.chat("openai")!.defaultEndpoint)
        #expect(Readiness.issues(prefs, allGood) == [.credentialMissing("openai")])
        prefs.ai = .cloud(CloudPreset.chat("ollama")!.defaultEndpoint)
        prefs.speech = .volcengine(appID: "")
        #expect(Readiness.issues(prefs, allGood) == [.aiModelNotChosen, .credentialMissing(.volcengine)])
    }
}

struct HistoryTests {
    private func entry(_ outcome: Outcome, age: TimeInterval = 0) -> HistoryEntry {
        HistoryEntry(id: UUID(), created: Date(timeIntervalSince1970: 1_000_000 - age), request: .dictate, app: nil,
                     audioSeconds: 3, hasAudio: true, outcome: outcome)
    }

    @Test func retentionKeepsUnfinishedEntriesForAtLeastADay() {
        let done = entry(.delivered("hi", .inserted))
        let failed = entry(.failed(.offline))
        #expect(Retention.forever.expiry(of: done) == nil)
        #expect(Retention.week.expiry(of: done) == done.created.addingTimeInterval(7 * 86_400))
        #expect(Retention.never.expiry(of: done) == done.created)
        #expect(Retention.never.expiry(of: failed) == failed.created.addingTimeInterval(86_400))
        #expect(Retention.month.expiry(of: failed) == failed.created.addingTimeInterval(30 * 86_400))
    }

    @Test func outcomesThatInviteARetry() {
        #expect(Outcome.pending.isUnfinished)
        #expect(Outcome.failed(.interrupted).isUnfinished)
        #expect(!Outcome.delivered("x", .copied).isUnfinished)
        #expect(!Outcome.nothingSaid.isUnfinished)
    }

    @Test func entriesRoundTrip() throws {
        let original = HistoryEntry(id: UUID(), created: Date(timeIntervalSince1970: 5), request: .translate(to: "ja"),
                                    app: "com.apple.mail", audioSeconds: 2.5, hasAudio: true, transcript: "你好",
                                    outcome: .failed(.rejected("model not found")))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(HistoryEntry.self, from: data) == original)
    }

    @Test func wordCountTreatsCJKCharactersAsWords() {
        #expect(WordCount.count("Hello, world!") == 2)
        #expect(WordCount.count("我们用 Swift 写") == 5)
        #expect(WordCount.count("don't stop, it's 2026") == 4)
        #expect(WordCount.count("日本語のテキスト") == 8)
        #expect(WordCount.count("") == 0)
    }

    @Test func usageStats() {
        var stats = UsageStats()
        stats.record("one two three four five six seven eight nine ten", spokenSeconds: 5)
        #expect(stats.words == 10 && stats.dictations == 1)
        #expect(stats.wordsPerMinute == 120)
        #expect(stats.timeSaved == .seconds(10))
        #expect(UsageStats(words: 1, dictations: 1, spokenSeconds: 60).timeSaved == .zero)
    }
}
