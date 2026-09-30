import Foundation
import Testing

/// Every string the app shows must have a Simplified Chinese translation with the same format arguments. Keys are
/// the English text passed to `tr("…")`, the one lookup the runtime language switch reaches.
struct LocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Code only: comments that quote an API (`Text("…")`) are not strings the app shows.
    private static func sources() throws -> [(name: String, text: String)] {
        let folder = root.appending(path: "Sources/SaidDoneApp")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { file in
            let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return (file.lastPathComponent, code)
        }
    }

    /// `(?<![\w.])` keeps `x.tr(` and `str(` out.
    private static let pattern = try! NSRegularExpression(pattern: #"(?<![\w.])tr\("((?:[^"\\]|\\.)*)""#)

    static func keys(in text: String) -> [String] {
        let source = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range(at: 1)) }
            .map { $0.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\") }
    }

    private static func translations() throws -> [String: String] {
        let url = root.appending(path: "Resources/zh-Hans.lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    private static func arguments(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(@|lld)")
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map { (text as NSString).substring(with: $0.range) }
    }

    @Test func sourcesAreScanned() throws {
        let all = try Self.sources().flatMap { Self.keys(in: $0.text) }
        #expect(all.count > 200)
        #expect(Self.keys(in: #"Text(tr("A \"b\"")) Text(verbatim: "no") tr("C %@", x) x.tr("no")"#) == [#"A "b""#, "C %@"])
    }

    @Test func everyKeyHasATranslation() throws {
        let translations = try Self.translations()
        var missing: Set<String> = []
        for (_, text) in try Self.sources() {
            for key in Self.keys(in: text) where translations[key] == nil { missing.insert(key) }
        }
        #expect(missing.isEmpty, "missing zh-Hans for:\n\(missing.sorted().map { "\"\($0)\" = \"\";" }.joined(separator: "\n"))")
    }

    @Test func translationsKeepTheirArguments() throws {
        for (key, value) in try Self.translations() {
            #expect(Self.arguments(key) == Self.arguments(value), "\(key) → \(value)")
        }
    }

    @Test func noUnusedTranslations() throws {
        let used = Set(try Self.sources().flatMap { Self.keys(in: $0.text) })
        let unused = try Self.translations().keys.filter { !used.contains($0) }
        #expect(unused.isEmpty, "unused: \(unused.sorted())")
    }

    /// An interpolated literal becomes a key with `%@` that no one wrote a translation for; `tr` takes arguments.
    @Test func literalKeysAreNotInterpolated() throws {
        for (name, text) in try Self.sources() {
            for key in Self.keys(in: text) {
                #expect(!key.contains(#"\("#), "\(name): \(key)")
            }
        }
    }

    /// SwiftUI localizes a literal title (`Text("…")`, `Button("…")`) itself, bypassing the language switch and this
    /// check: titles take `tr("…")`, or `verbatim:` for text that is never translated.
    @Test func titlesGoThroughTr() throws {
        let regex = try NSRegularExpression(
            pattern: #"(?<![\w.])(Text|Label|Button|Toggle|Picker|Section|TextField|SecureField|LabeledContent|Menu|Link)\(""#)
        for (name, text) in try Self.sources() {
            let count = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            #expect(count == 0, "\(name) has a literal title")
        }
    }
}
