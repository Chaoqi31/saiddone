import AppKit
import SaidDoneCore
import SwiftUI

/// Every window, panel and menu. Views receive the parts they show; panels follow the state they present.
@MainActor
final class Windows: NSObject, NSMenuDelegate {
    private unowned let root: AppRoot
    private var main: NSWindow?
    private var onboarding: NSWindow?
    private var statusItem: NSStatusItem?
    private lazy var voiceBar = FloatingPanel(Localized(root.localization) {
        VoiceBar(root: self.root)
    })
    private lazy var answerPanel = FloatingPanel(Localized(root.localization) {
        AnswerPanelView(panel: self.root.answers)
    })

    init(root: AppRoot) {
        self.root = root
    }

    func install() {
        NSApp.mainMenu = mainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item
        Observe.track { StatusIcon(phase: self.root.dictation.phase, blocked: self.root.setup.recordingBlocker != nil) }
            apply: { icon in
                item.button?.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: "SaidDone")
                item.button?.contentTintColor = icon.tint
            }
        Observe.track { self.root.dictation.phase != .idle || self.root.dictation.notice != nil } apply: { visible in
            if visible { self.voiceBar.present(at: .bottom) } else { self.voiceBar.orderOut(nil) }
        }
        Observe.track { self.root.answers.isVisible } apply: { visible in
            if visible { self.answerPanel.present(at: .center) } else { self.answerPanel.orderOut(nil) }
        }
    }

    /// Until onboarding is finished, the Setup Assistant stands in for the main window.
    func showMain(_ pane: Pane? = nil) {
        guard root.settings.prefs.onboardingCompleted else { return showOnboarding() }
        if let pane { root.navigation.pane = pane }
        let window = main ?? makeWindow(title: "SaidDone", size: NSSize(width: 900, height: 620),
                                        resizable: true) { MainView(root: self.root) }
        main = window
        present(window)
    }

    func showOnboarding() {
        let window = onboarding ?? makeWindow(title: tr("Welcome to SaidDone"), size: NSSize(width: 680, height: 560),
                                              resizable: false) { OnboardingView(root: self.root) }
        onboarding = window
        present(window)
    }

    func closeOnboarding() {
        onboarding?.close()
        onboarding = nil
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, resizable: Bool,
                                           content: @escaping () -> Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered,
                              defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Localized(root.localization, content: content))
        window.setContentSize(size)
        window.center()
        return window
    }

    // MARK: - Menus

    /// An accessory app shows no menu bar, but key equivalents still route through the main menu: without these
    /// items ⌘C, ⌘V and ⌘W do nothing in SaidDone's own windows.
    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu?.addItem($0) }
            menu.addItem(item)
        }
        submenu("SaidDone", [
            NSMenuItem(title: tr("About SaidDone"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                       keyEquivalent: ""),
            .separator(),
            action(tr("Settings…"), key: ",") { self.showMain(.general) },
            .separator(),
            NSMenuItem(title: tr("Hide SaidDone"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            NSMenuItem(title: tr("Quit SaidDone"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        submenu(tr("Edit"), [
            NSMenuItem(title: tr("Undo"), action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: tr("Redo"), action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: tr("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: tr("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: tr("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: tr("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        submenu(tr("Window"), [
            NSMenuItem(title: tr("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: tr("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
        ])
        return menu
    }

    /// The status menu is rebuilt each time it opens, so it always shows the current state and language.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let dictation = root.dictation
        let shortcuts = root.settings.prefs.shortcuts
        if let issue = root.setup.recordingBlocker {
            menu.addItem(action(issue.title, symbol: "exclamationmark.triangle") { self.root.fix(issue) })
            menu.addItem(.separator())
        }
        switch dictation.phase {
        case .recording:
            menu.addItem(action(tr("Finish"), symbol: "checkmark") { dictation.finish() })
            menu.addItem(action(tr("Cancel"), symbol: "xmark") { dictation.cancel() })
        case .processing:
            menu.addItem(action(tr("Cancel"), symbol: "xmark") { dictation.cancel() })
        case .idle:
            for mode in Mode.allCases {
                let item = action(mode.title, symbol: mode.symbol) { dictation.start(mode) }
                if let trigger = shortcuts.triggers(for: mode).first {
                    item.attributedTitle = Self.title(mode.title, detail: trigger.label)
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(action(tr("Open SaidDone"), symbol: "macwindow") { self.showMain() })
        menu.addItem(action(tr("History"), symbol: "clock") { self.showMain(.history) })
        menu.addItem(action(tr("Settings…"), symbol: "gearshape", key: ",") { self.showMain(.general) })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("Quit SaidDone"), action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func action(_ title: String, symbol: String? = nil, key: String = "",
                        _ perform: @escaping @MainActor @Sendable () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, perform: perform)
        item.keyEquivalent = key
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private static func title(_ title: String, detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title + "   ")
        text.append(NSAttributedString(string: detail, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }
}

/// The menu bar icon for the current state.
private struct StatusIcon: Equatable {
    let symbol: String
    let tint: NSColor?

    init(phase: Dictation.Phase, blocked: Bool) {
        switch phase {
        case .recording:
            symbol = "waveform.circle.fill"
            tint = .systemRed
        case .processing:
            symbol = "ellipsis.circle"
            tint = nil
        case .idle:
            symbol = blocked ? "exclamationmark.triangle" : "waveform"
            tint = nil
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let perform: @MainActor @Sendable () -> Void

    init(title: String, perform: @escaping @MainActor @Sendable () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// AppKit sends menu actions on the main thread.
    @objc private func run() { MainActor.assumeIsolated { [perform] in perform() } }
}

/// A HUD panel that never takes focus: the voice bar and the answer panel float over the user's app, which keeps
/// the keyboard, so a paste still lands where they were typing.
final class FloatingPanel: NSPanel {
    enum Placement { case bottom, center }

    init<Content: View>(_ content: Content) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Never key, so controls would draw as inactive: keep them looking live.
        let controller = NSHostingController(rootView: content.environment(\.controlActiveState, .key))
        controller.sizingOptions = [.preferredContentSize]
        contentViewController = controller
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The hosting controller resizes the panel whenever its content changes, keeping the top edge; keep the bottom
    /// edge and the horizontal center instead, so the bar grows upward from where it was placed.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if rect.size != frame.size, frame.size != .zero {
            rect.origin = NSPoint(x: frame.midX - rect.width / 2, y: frame.minY)
        }
        super.setFrame(rect, display: flag)
    }

    /// On the screen with the pointer, where the user is looking.
    func present(at placement: Placement) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let size = frame.size
        let origin = switch placement {
        case .bottom: NSPoint(x: area.midX - size.width / 2, y: area.minY + 72)
        case .center: NSPoint(x: area.midX - size.width / 2, y: area.minY + area.height * 0.55 - size.height / 2)
        }
        if !isVisible { setFrameOrigin(origin) }
        orderFrontRegardless()
    }
}

/// Re-creates its content when the interface language changes, so every string is looked up again.
struct Localized<Content: View>: View {
    let localization: Localization
    @ViewBuilder let content: () -> Content

    init(_ localization: Localization, @ViewBuilder content: @escaping () -> Content) {
        self.localization = localization
        self.content = content
    }

    var body: some View {
        content()
            .environment(\.locale, localization.locale)
            .id(localization.locale.identifier)
    }
}
