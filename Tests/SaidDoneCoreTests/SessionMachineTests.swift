import Foundation
import Testing
@testable import SaidDoneCore

private final class JobIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    func make() -> JobID {
        lock.lock(); defer { lock.unlock() }
        next += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", next))!
    }
    static func id(_ n: Int) -> JobID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
}

private let g1 = GestureID(raw: 1)
private let g2 = GestureID(raw: 2)
private let r1 = RecordingID(raw: 1)
private let r2 = RecordingID(raw: 2)
private let job1 = JobIDs.id(1)
private let job2 = JobIDs.id(2)

private func machine() -> SessionMachine {
    let ids = JobIDs()
    return SessionMachine(makeJobID: { ids.make() })
}

struct SessionMachineTests {
    @Test func tapStartsHandsFreeAndTheNextPressFinishes() {
        var m = machine()
        #expect(m.handle(.gesture(.pressed(.dictation, g1))) == [.beginRecording(r1, .dictation)])
        #expect(m.handle(.gesture(.released(.dictation, g1, held: .milliseconds(120))))
                == [.styleDecided(r1, .toggle)])
        #expect(m.handle(.gesture(.pressed(.dictation, g2))) == [.endRecording(r1, .dictation, job1)])
        #expect(m.recording == nil)
        #expect(m.jobs == [.init(id: job1, ready: false)])
    }

    @Test func holdEndsOnRelease() {
        var m = machine()
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        #expect(m.handle(.gesture(.released(.dictation, g1, held: .seconds(3))))
                == [.endRecording(r1, .dictation, job1)])
    }

    @Test func holdThresholdBoundary() {
        var m = machine()
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        #expect(m.handle(.gesture(.released(.dictation, g1, held: SessionMachine.holdThreshold)))
                == [.endRecording(r1, .dictation, job1)])
    }

    @Test func finishingHandsFreeWithAnotherShortcutPicksItsMode() {
        var m = machine()
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        _ = m.handle(.gesture(.released(.dictation, g1, held: .milliseconds(80))))
        #expect(m.handle(.gesture(.pressed(.translation, g2)))
                == [.changeMode(r1, .translation), .endRecording(r1, .translation, job1)])
    }

    @Test func chordGrowthWhileHoldingSwitchesMode() {
        var m = machine()
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        #expect(m.handle(.gesture(.retargeted(.translation, g1))) == [.changeMode(r1, .translation)])
        #expect(m.handle(.gesture(.released(.translation, g1, held: .seconds(2))))
                == [.endRecording(r1, .translation, job1)])
    }

    @Test func otherModeComboWhileHoldingSwitchesAndSameModeFinishes() {
        var m = machine()
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        #expect(m.handle(.gesture(.pressed(.ask, g2))) == [.changeMode(r1, .ask)])
        #expect(m.handle(.gesture(.pressed(.ask, GestureID(raw: 3)))) == [.endRecording(r1, .ask, job1)])
    }

    @Test func abortedPressDiscardsOnlyWhileUndecided() {
        var m = machine()
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        #expect(m.handle(.gesture(.aborted(g1))) == [.discardRecording(r1)])
        #expect(m.recording == nil)
        #expect(m.jobs.isEmpty)
    }

    @Test func escapeCancelsTheRecordingThenTheRunningJob() {
        var m = machine()
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        _ = m.handle(.gesture(.released(.dictation, g1, held: .seconds(1))))
        _ = m.handle(.jobReady(job1))
        _ = m.handle(.gesture(.pressed(.dictation, g2)))
        #expect(m.handle(.gesture(.escape)) == [.discardRecording(r2)])
        #expect(m.handle(.gesture(.escape)) == [.cancelJob(job1)])
        #expect(m.handle(.jobEnded(job1)) == [])
        #expect(m.handle(.gesture(.escape)) == [])
        #expect(!m.isBusy)
    }

    /// The host drops a job cancelled before it is ready once it has been saved.
    @Test func escapeRightAfterFinishingCancelsTheJobBeingSaved() {
        var m = machine()
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        _ = m.handle(.gesture(.released(.dictation, g1, held: .seconds(1))))
        #expect(m.handle(.gesture(.escape)) == [.cancelJob(job1)])
        #expect(m.handle(.jobDropped(job1)) == [])
        #expect(!m.isBusy)
    }

    @Test func pressDuringProcessingRecordsAndJobsRunInOrder() {
        var m = machine()
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        _ = m.handle(.gesture(.released(.dictation, g1, held: .seconds(1))))      // job1 queued
        #expect(m.handle(.gesture(.pressed(.translation, g2))) == [.beginRecording(r2, .translation)])
        _ = m.handle(.gesture(.released(.translation, g2, held: .seconds(1))))    // job2 queued
        // job2 becomes durable first: it must still wait for job1.
        #expect(m.handle(.jobReady(job2)) == [])
        #expect(m.handle(.jobReady(job1)) == [.runJob(job1)])
        #expect(m.handle(.jobEnded(job1)) == [.runJob(job2)])
        #expect(m.handle(.jobEnded(job2)) == [])
    }

    @Test func droppedHeadLetsTheNextReadyJobRun() {
        var m = machine()
        _ = m.handle(.start(.dictation))
        _ = m.handle(.finish)
        _ = m.handle(.start(.dictation))
        _ = m.handle(.finish)
        _ = m.handle(.jobReady(job2))
        #expect(m.handle(.jobDropped(job1)) == [.runJob(job2)])
    }

    @Test func menuStartIsHandsFree() {
        var m = machine()
        #expect(m.handle(.start(.ask)) == [.beginRecording(r1, .ask)])
        #expect(m.recording?.style == .toggle)
        #expect(m.handle(.finish) == [.endRecording(r1, .ask, job1)])
    }

    @Test func staleAndForeignEventsAreInert() {
        var m = machine()
        #expect(m.handle(.gesture(.released(.dictation, g1, held: .seconds(1)))) == [])
        #expect(m.handle(.gesture(.aborted(g1))) == [])
        #expect(m.handle(.finish) == [])
        #expect(m.handle(.jobEnded(job1)) == [])
        _ = m.handle(.gesture(.pressed(.dictation, g1)))
        #expect(m.handle(.gesture(.released(.dictation, g2, held: .seconds(1)))) == [])
        #expect(m.handle(.captureFailed(r2)) == [])
        #expect(m.recording != nil)
        #expect(m.handle(.captureFailed(r1)) == [])
        #expect(m.recording == nil)
    }

    @Test func retryQueuesBehindRunningWork() {
        var m = machine()
        let old = UUID()
        #expect(m.handle(.retry(old)) == [.runJob(old)])
        #expect(m.handle(.retry(old)) == [], "a job is queued once")
        _ = m.handle(.start(.dictation))
        _ = m.handle(.finish)
        _ = m.handle(.jobReady(job1))
        #expect(m.handle(.jobEnded(old)) == [.runJob(job1)])
    }
}
