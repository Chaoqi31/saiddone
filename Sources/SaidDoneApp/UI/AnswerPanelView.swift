import SwiftUI

/// The Ask Anything answer. Floats over the user's app without taking focus, so Insert pastes where they were.
struct AnswerPanelView: View {
    let panel: AnswerPanel

    var body: some View {
        if let answer = panel.current {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    Text(verbatim: answer.question)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button(action: panel.close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help(tr("Close (Esc)"))
                        .accessibilityLabel(tr("Close"))
                }
                ScrollView {
                    Text(Self.render(answer.text))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(tr("Copy"), action: panel.copy)
                    Button(tr("Insert"), action: panel.insert)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(16)
            .frame(width: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .padding(12)
        }
    }

    /// Bold, italics, code and links; line breaks kept as the model wrote them.
    static func render(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
