import Foundation
import Testing
@testable import SaidDoneCore

private struct StubTranscriber: Transcriber {
    var result: Result<String, EngineError>
    func transcribe(_ audio: AudioSamples, hints: RecognitionHints) async throws(EngineError) -> String {
        try result.get()
    }
}

/// Replies from a script, one per call; records every prompt.
private final class ScriptedChat: ChatModel, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<String, EngineError>]
    private(set) var prompts: [Prompt] = []
    let delay: Duration

    init(_ replies: [Result<String, EngineError>], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    func reply(to prompt: Prompt) async throws(EngineError) -> String {
        let next: Result<String, EngineError> = lock.withLock {
            prompts.append(prompt)
            return replies.isEmpty ? .success("") : replies.removeFirst()
        }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { throw .cancelled }
        }
        return try next.get()
    }
}

private let speech = AudioSamples(samples: [Float](repeating: 0.2, count: 16_000))

private func run(heard: String, replies: [Result<String, EngineError>], _ request: Request = .dictate,
                 context: JobContext = JobContext(), budget: Duration? = nil) async
-> (Result<PipelineResult, PipelineFailure>, ScriptedChat) {
    let chat = ScriptedChat(replies)
    let pipeline = Pipeline(transcriber: StubTranscriber(result: .success(heard)), chat: chat)
    do throws(PipelineFailure) {
        return (.success(try await pipeline.run(speech, request, context, budget: budget)), chat)
    } catch {
        return (.failure(error), chat)
    }
}

struct PipelineTests {
    @Test func dictationCorrectsTermsBeforeThePromptAndInsertsTheReply() async throws {
        var lexicon = Lexicon()
        lexicon.add("Vercel", misheard: ["Verso"], at: .now)
        let (result, chat) = await run(heard: "deploy it on Verso", replies: [.success("Deploy it on Vercel.")],
                                       context: JobContext(lexicon: lexicon))
        let value = try result.get()
        #expect(value.transcript == "deploy it on Vercel")
        #expect(value.output == .insert("Deploy it on Vercel."))
        #expect(chat.prompts.first?.user.contains("deploy it on Vercel") == true)
        #expect(chat.prompts.first?.system.contains("【术语表】") == true)
    }

    @Test func blankAndFillerTranscriptsNeverReachTheModel() async throws {
        let (blank, chat1) = await run(heard: "  ", replies: [])
        #expect(try blank.get().output == .nothing(.noSpeech))
        let (filler, chat2) = await run(heard: "嗯 那个 就是 呃", replies: [])
        #expect(try filler.get().output == .nothing(.nothingSaid))
        #expect(chat1.prompts.isEmpty && chat2.prompts.isEmpty)
    }

    @Test func emptyReplyIsRetriedOnceThenFailsKeepingTheTranscript() async throws {
        let (retried, chat) = await run(heard: "send the report", replies: [.success(""), .success("Send the report.")])
        #expect(try retried.get().output == .insert("Send the report."))
        #expect(chat.prompts.count == 2)

        let (failed, _) = await run(heard: "send the report", replies: [.success(""), .success("（空文本）")])
        #expect(failed == .failure(PipelineFailure(reason: .emptyReply, stage: .polishing, transcript: "send the report")))
    }

    @Test func emptyReplyForASpokenCancelIsNothingSaid() async throws {
        let (result, chat) = await run(heard: "给小王发消息说明天开会 算了", replies: [.success("")])
        #expect(try result.get().output == .nothing(.nothingSaid))
        #expect(chat.prompts.count == 1)
    }

    @Test func realContentBeforeACancelWordIsKept() async throws {
        let (result, _) = await run(heard: "给小王发消息说明天开会 算了", replies: [.success("给小王发消息，说明天开会。")])
        #expect(try result.get().output == .insert("给小王发消息，说明天开会。"))
    }

    @Test func engineErrorsKeepTheirStage() async {
        let pipeline = Pipeline(transcriber: StubTranscriber(result: .failure(.offline)), chat: ScriptedChat([]))
        do throws(PipelineFailure) {
            _ = try await pipeline.run(speech, .dictate, JobContext(), budget: nil)
            Issue.record("expected a failure")
        } catch {
            #expect(error == PipelineFailure(reason: .offline, stage: .transcribing, transcript: nil))
        }
        let (result, _) = await run(heard: "hello", replies: [.failure(.rejected("model not found"))],
                                    .translate(to: .english))
        #expect(result == .failure(PipelineFailure(reason: .rejected("model not found"), stage: .translating,
                                                   transcript: "hello")))
    }

    @Test func slowModelTimesOutAtTheBudget() async {
        let chat = ScriptedChat([.success("late")], delay: .seconds(5))
        let pipeline = Pipeline(transcriber: StubTranscriber(result: .success("hello there")), chat: chat)
        let clock = ContinuousClock()
        let start = clock.now
        do throws(PipelineFailure) {
            _ = try await pipeline.run(speech, .dictate, JobContext(), budget: .milliseconds(100))
            Issue.record("expected a timeout")
        } catch {
            #expect(error.reason == .timeout)
            #expect(error.transcript == "hello there")
        }
        #expect(start.duration(to: clock.now) < .seconds(2))
    }

    @Test func cancellingTheJobEndsItPromptly() async {
        let chat = ScriptedChat([.success("late")], delay: .seconds(5))
        let pipeline = Pipeline(transcriber: StubTranscriber(result: .success("hello there")), chat: chat)
        let task = Task { () async throws(PipelineFailure) -> PipelineResult in
            try await pipeline.run(speech, .dictate, JobContext(), budget: .seconds(30))
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a cancellation")
        } catch {
            #expect(error as? PipelineFailure == PipelineFailure(reason: .cancelled, stage: .polishing,
                                                                 transcript: "hello there"))
        }
    }

    @Test func askWithoutSelectionOpensSpokenSearches() async throws {
        let (result, chat) = await run(heard: "search swift actors on YouTube", replies: [], .ask(selection: ""))
        #expect(try result.get().output == .open(URL(string: "https://www.youtube.com/results?search_query=swift%20actors")!))
        #expect(chat.prompts.isEmpty)
    }

    @Test func askEditsTheSelectionOnlyWhenTheModelSaysEdit() async throws {
        let (edit, _) = await run(heard: "make it shorter", replies: [.success("EDIT:\nShort.")],
                                  .ask(selection: "A long sentence."))
        #expect(try edit.get().output == .replaceSelection("Short."))
        let (answer, _) = await run(heard: "what does this mean", replies: [.success("It means X.")],
                                    .ask(selection: "A long sentence."))
        #expect(try answer.get().output == .answer("It means X."))
    }

    @Test func budgetScalesWithAudioForCloudOnly() {
        #expect(Budget.ai(local: true, audio: .seconds(60)) == .seconds(30))
        #expect(Budget.ai(local: false, audio: .seconds(1)) == .seconds(8))
        #expect(Budget.ai(local: false, audio: .seconds(60)) == .seconds(24))
    }
}
