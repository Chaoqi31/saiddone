import AppKit
import SaidDoneCore
import SwiftUI

/// A rounded panel with a titled header, for Home and onboarding.
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var attention = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(attention ? Color.orange : Color.accentColor)
            }
            .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(attention ? Color.orange.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(attention ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08)))
    }
}

/// A shortcut drawn as keyboard keys.
struct Keycaps: View {
    let trigger: Trigger

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(trigger.keycaps.enumerated()), id: \.offset) { _, cap in
                Text(verbatim: cap)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2)))
                    .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trigger.label)
    }
}

/// One setup problem with the button that fixes it.
struct IssueRow: View {
    let issue: Issue
    let library: ModelLibrary
    let fix: (Issue) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.blocksRecording ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(issue.blocksRecording ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: issue.title).font(.body.weight(.medium))
                Text(verbatim: issue.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case let .modelNotInstalled(model) = issue, let progress = library.progress[model] {
                ProgressView(value: progress).frame(width: 90)
                Button(tr("Cancel")) { library.cancel(model) }
            } else {
                Button(buttonTitle) { fix(issue) }
            }
        }
        .controlSize(.small)
    }

    private var buttonTitle: String {
        switch issue {
        case .microphoneNotAllowed, .accessibilityNotAllowed: tr("Allow")
        case .globeKeyAssigned: tr("Open Keyboard Settings")
        case .modelNotInstalled: tr("Download")
        case .credentialMissing: tr("Add Key")
        case .speechModelNotChosen, .aiModelNotChosen, .onDeviceAIUnavailable: tr("Choose")
        }
    }
}

/// The app icon: a speech bubble with a checkmark. Mirrors scripts/make-icon.sh.
struct BrandMark: View {
    var size: CGFloat = 56

    private let background = Color(red: 0.055, green: 0.055, blue: 0.067)

    var body: some View {
        let k = size / 1024
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).fill(background)
            bubble(k).fill(.white)
            check(k).stroke(background, style: StrokeStyle(lineWidth: 66 * k, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func bubble(_ k: CGFloat) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 242 * k, y: 240 * k, width: 540 * k, height: 392 * k),
                            cornerSize: CGSize(width: 150 * k, height: 150 * k))
        path.move(to: CGPoint(x: 322 * k, y: 592 * k))
        path.addLine(to: CGPoint(x: 486 * k, y: 592 * k))
        path.addLine(to: CGPoint(x: 312 * k, y: 724 * k))
        path.closeSubpath()
        return path
    }

    private func check(_ k: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 424 * k, y: 448 * k))
        path.addLine(to: CGPoint(x: 500 * k, y: 526 * k))
        path.addLine(to: CGPoint(x: 658 * k, y: 358 * k))
        return path
    }
}

/// Names and icons of other apps, by bundle identifier.
enum Apps {
    static func name(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
