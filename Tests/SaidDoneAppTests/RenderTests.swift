import AppKit
import SaidDoneCore
import SwiftUI
import Testing
@testable import SaidDoneApp

/// Draws every screen to PNGs in /tmp/saiddone-render for review, in English and Chinese. Opt in with
/// SAIDDONE_UI=1; each render must also contain more than a blank background.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SAIDDONE_UI"] != nil))
struct RenderTests {
    private static let output = URL(fileURLWithPath: "/tmp/saiddone-render")
    private static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")

    private let root: AppRoot

    init() async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory.appending(path: "SaidDoneRender-\(UUID().uuidString)")
        root = AppRoot(paths: AppPaths(root: folder), keychain: nil)
        root.settings.prefs.onboardingCompleted = true
        root.dictionary.lexicon.add("Vercel", misheard: ["Verso", "vessel"], at: .now)
        root.dictionary.lexicon.add("SaidDone", at: .now)
        root.dictionary.lexicon.learn([Correction(heard: "get hub", meant: "GitHub")], at: .now)
        let samples = AudioSamples(samples: [Float](repeating: 0.1, count: 16_000))
        let jobs: [(Request, String, Outcome)] = [
            (.dictate, "嗯那个我们周五下午三点开会吧", .delivered("我们周五下午三点开会吧。", .inserted)),
            (.translate(to: .english), "明天见", .delivered("See you tomorrow.", .inserted)),
            (.ask(selection: ""), "what is the capital of australia", .delivered("Canberra.", .answered)),
            (.dictate, "deploy it on verso", .failed(.offline)),
        ]
        for (index, job) in jobs.enumerated() {
            let entry = HistoryEntry(id: UUID(), created: .now.addingTimeInterval(Double(index - 10) * 600),
                                     request: job.0, app: "com.apple.TextEdit", audioSeconds: 4, hasAudio: false)
            await root.history.open(entry, audio: samples)
            await root.history.close(entry.id, transcript: job.1, outcome: job.2, retention: .forever)
            await root.history.recordUsage(job.1, spokenSeconds: 4)
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test(arguments: ["en", "zh-Hans"])
    func mainWindow(_ language: String) throws {
        use(language)
        for pane in Pane.allCases {
            root.navigation.pane = pane
            try render(MainView(root: root), "main-\(pane.rawValue)-\(language)", CGSize(width: 900, height: 640))
        }
    }

    @Test(arguments: ["en", "zh-Hans"])
    func onboarding(_ language: String) throws {
        use(language)
        root.settings.prefs.onboardingCompleted = false
        for step in OnboardingView.Step.allCases {
            try render(OnboardingView(root: root, step: step), "onboarding-\(step)-\(language)",
                       CGSize(width: 680, height: 560))
        }
    }

    @Test(arguments: ["en", "zh-Hans"])
    func voiceBarAndAnswer(_ language: String) throws {
        use(language)
        let rows: [(String, AnyView)] = [
            ("recording", AnyView(RecordingRow(root: root, mode: .dictation, style: .toggle, since: .now.addingTimeInterval(-7)))),
            ("translating", AnyView(RecordingRow(root: root, mode: .translation, style: .undecided, since: .now))),
            ("processing", AnyView(ProcessingRow(stage: .polishing, waiting: 1, cancel: {}))),
            ("failed", AnyView(NoticeRow(notice: .failed(.offline, entry: UUID(), transcript: "hello"), root: root))),
            ("setup", AnyView(NoticeRow(notice: .setupNeeded(.accessibilityNotAllowed), root: root))),
            ("learned", AnyView(NoticeRow(notice: .learned(["Vercel"]), root: root))),
        ]
        for (name, row) in rows {
            try render(row.modifier(Bar()).frame(width: 420).padding(12), "voicebar-\(name)-\(language)",
                       CGSize(width: 444, height: 80))
        }
        root.answers.show(question: "what's a good name for a cat",
                          answer: "**Miso** is short and warm. Other ideas:\n- Mochi\n- Pepper\n- `Luna`")
        try render(AnswerPanelView(panel: root.answers), "answer-\(language)", CGSize(width: 504, height: 260))
        root.answers.close()
    }

    private func use(_ language: String) {
        Localization.install("en")
        ForwardingBundle.target = Bundle(url: Self.resources.appending(path: "\(language).lproj"))
    }

    private func render(_ view: some View, _ name: String, _ size: CGSize) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.locale, Locale(identifier: ForwardingBundle.target?.bundleURL.deletingPathExtension()
                .lastPathComponent ?? "en")))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.current.run(until: .now.addingTimeInterval(0.4))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: Self.output.appending(path: "\(name).png"))
        #expect(Self.distinctColors(bitmap) > 8, "\(name) looks blank")
    }

    private static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var colors: Set<UInt32> = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colors.insert(UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
                              | UInt32(color.blueComponent * 255))
            }
        }
        return colors.count
    }
}
