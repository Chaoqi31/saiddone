import Foundation
import Testing
@testable import SaidDoneCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

struct LexiconTests {
    private func lexicon(_ terms: [(String, [String])]) -> Lexicon {
        var lexicon = Lexicon()
        for (text, misheard) in terms { lexicon.add(text, misheard: misheard, at: t0) }
        return lexicon
    }

    @Test func replacesWholeASCIIWordsCaseInsensitively() {
        let lexicon = lexicon([("Claude", ["clod"])])
        #expect(lexicon.correct("i asked clod and Clod") == "i asked Claude and Claude")
        #expect(lexicon.correct("clodhopper") == "clodhopper")
    }

    @Test func cjkMatchesAsSubstring() {
        #expect(lexicon([("Simon", ["塞门"])]).correct("我叫塞门") == "我叫Simon")
    }

    @Test func longestVariantWinsAndReplacementsAreNotReplacedAgain() {
        let lexicon = lexicon([("VS Code", ["vs code"]), ("Coder", ["code"])])
        #expect(lexicon.correct("open vs code, then code") == "open VS Code, then Coder")
    }

    @Test func regexCharactersAreLiteral() {
        #expect(lexicon([("C++", ["c plus plus"])]).correct("i write c plus plus") == "i write C++")
        #expect(lexicon([("Objective-C", ["objc++"])]).correct("objc++ code") == "Objective-C code")
    }

    @Test func casingIsFixedOnlyForCaseSensitiveTerms() {
        let lexicon = lexicon([("GitHub", []), ("JSON", []), ("Apple", []), ("US", [])])
        #expect(lexicon.correct("push to github as json") == "push to GitHub as JSON")
        #expect(lexicon.correct("an apple for us") == "an apple for us")
    }

    @Test func learnedMishearingsAreHintsNotReplacements() {
        var lexicon = Lexicon()
        lexicon.learn([Correction(heard: "Verso", meant: "Vercel")], at: t0)
        #expect(lexicon.correct("deploy on Verso") == "deploy on Verso")
        #expect(lexicon.recognitionHints() == ["Vercel"])
        #expect(lexicon.terms.first?.origin == .learned)
    }

    @Test func learningIsIdempotentAndNeverHijacksAnotherTerm() {
        var lexicon = lexicon([("Swift", [])])
        #expect(lexicon.learn([Correction(heard: "Swift", meant: "SwiftUI")], at: t0).isEmpty)
        let first = lexicon.learn([Correction(heard: "Verso", meant: "Vercel")], at: t0)
        let again = lexicon.learn([Correction(heard: "Verso", meant: "Vercel")], at: t0)
        #expect(first.map(\.text) == ["Vercel"])
        #expect(again.isEmpty)
        #expect(lexicon.terms.count == 2)
    }

    @Test func addingALearnedSpellingMakesItManual() {
        var lexicon = Lexicon()
        lexicon.learn([Correction(heard: "Verso", meant: "Vercel")], at: t0)
        lexicon.add("vercel", misheard: ["vessel"], at: t0)
        #expect(lexicon.terms.count == 1)
        #expect(lexicon.terms[0].origin == .manual)
        #expect(lexicon.terms[0].misheard == ["Verso", "vessel"])
        #expect(lexicon.correct("on Verso") == "on vercel")
    }

    @Test func hintsListManualTermsFirstNewestFirst() {
        var lexicon = Lexicon()
        lexicon.add("Old", at: t0)
        lexicon.add("New", at: t0.addingTimeInterval(10))
        lexicon.learn([Correction(heard: "Verso", meant: "Vercel")], at: t0.addingTimeInterval(20))
        #expect(lexicon.recognitionHints() == ["New", "Old", "Vercel"])
        #expect(lexicon.recognitionHints(limit: 1) == ["New"])
    }

    @Test func recognitionPromptIsASentenceInTheSpokenLanguage() {
        func prompt(_ language: Language?, _ terms: [String]) -> String? {
            RecognitionHints(language: language, vocabulary: terms).prompt
        }
        #expect(prompt(.chinese, ["API", "bug", "Vercel"]) == "我们刚才聊到了 API、bug 和 Vercel。")
        #expect(prompt(.chinese, ["API"]) == "我们刚才聊到了 API。")
        #expect(prompt(.chinese, []) == "以下是普通话的句子。")
        #expect(prompt(.english, ["API", "bug"]) == "We just talked about API and bug.")
        #expect(prompt(.english, [""]) == nil)
        #expect(prompt("ja", ["API", "bug"]) == "API, bug.")
        #expect(prompt(nil, []) == nil)
    }

    @Test func editingRespellsAndMergesIntoAnExistingSpelling() throws {
        var lexicon = lexicon([("Vercel", ["Verso"]), ("Swift", [])])
        lexicon.learn([Correction(heard: "Sweeft", meant: "SwiftUI")], at: t0)
        let learned = try #require(lexicon.terms.first { $0.text == "SwiftUI" })
        let respelled = lexicon.edit(learned.id, text: " SwiftUI ", misheard: ["swift ui", ""])
        #expect(respelled)
        let edited = try #require(lexicon.terms.first { $0.id == learned.id })
        #expect(edited.origin == .manual)
        #expect(edited.misheard == ["swift ui"])

        let swift = try #require(lexicon.terms.first { $0.text == "Swift" })
        let merged = lexicon.edit(swift.id, text: "vercel", misheard: ["vessel"])
        #expect(merged)
        #expect(lexicon.terms.map(\.text) == ["Vercel", "SwiftUI"])
        #expect(lexicon.terms[0].misheard == ["Verso", "vessel"])
        let emptied = lexicon.edit(edited.id, text: " , ", misheard: [])
        #expect(!emptied)
    }

    @Test func csvRoundTripsAndMerges() {
        var lexicon = Lexicon()
        #expect(lexicon.importCSV("Vercel,Verso|vessel\n\nSaidDone\n张三,章三\n", at: t0) == 3)
        let csv = lexicon.exportCSV()
        #expect(csv == "Vercel,Verso|vessel\nSaidDone\n张三,章三\n")
        var copy = Lexicon()
        copy.importCSV(csv, at: t0)
        copy.importCSV("vercel,versal", at: t0)
        #expect(copy.terms.map(\.text) == ["vercel", "SaidDone", "张三"])
        #expect(copy.terms[0].misheard == ["Verso", "vessel", "versal"])
    }

    @Test func termsCannotHoldSeparators() {
        #expect(Term.clean("  a,b|c\n ") == "a b c")
        #expect(Term.clean(" , ") == nil)
    }

    @Test func correctionsAreTermLikeOneToOneSwaps() {
        #expect(Lexicon.corrections(inserted: "deploy on Verso today", edited: "deploy on Vercel today")
                == [Correction(heard: "Verso", meant: "Vercel")])
        #expect(Lexicon.corrections(inserted: "push to github", edited: "push to GitHub")
                == [Correction(heard: "github", meant: "GitHub")])
        #expect(Lexicon.corrections(inserted: "their car", edited: "there car").isEmpty)
        #expect(Lexicon.corrections(inserted: "a b c", edited: "totally Different Text Now Here Ok More").isEmpty)
        #expect(Lexicon.corrections(inserted: "用 Verso 部署", edited: "用 Vercel 部署")
                == [Correction(heard: "Verso", meant: "Vercel")])
    }
}
