import Foundation
import Testing
import os
@testable import SwiftHakchi

struct SNESFirmwareDispatchGateTests {
    @Test func invalidationBeforeDispatchPreventsTheWriter() throws {
        let gate=SNESFirmwareDispatchGate(),calls=OSAllocatedUnfairLock(initialState:0)
        #expect(gate.invalidate())
        #expect(throws:(any Error).self) {try gate.dispatch {calls.withLock {$0 += 1}}}
        #expect(calls.withLock {$0} == 0)
    }
    @Test func dispatchIsSingleUseAndLateInvalidationIsUncertain() throws {
        let gate=SNESFirmwareDispatchGate(),calls=OSAllocatedUnfairLock(initialState:0)
        try gate.dispatch {calls.withLock {$0 += 1}}
        #expect(!gate.invalidate())
        #expect(throws:(any Error).self) {try gate.dispatch {calls.withLock {$0 += 1}}}
        #expect(calls.withLock {$0} == 1)
    }
    @Test func errorAfterClaimRemainsDispatchedAndCannotRetry() {
        struct Failure:Error {}
        let gate=SNESFirmwareDispatchGate()
        #expect(throws:Failure.self) {try gate.dispatch {throw Failure()}}
        #expect(!gate.invalidate())
        #expect(throws:(any Error).self) {try gate.dispatch {}}
    }
    @Test func failedBoundaryValidationPreventsDispatchAndRetry() {
        struct Failure:Error {}
        let allowed=OSAllocatedUnfairLock(initialState:false),calls=OSAllocatedUnfairLock(initialState:0)
        let gate=SNESFirmwareDispatchGate(validate:{if !allowed.withLock({$0}) {throw Failure()}})
        #expect(throws:Failure.self) {try gate.dispatch {calls.withLock {$0 += 1}}}
        allowed.withLock {$0=true}
        #expect(throws:(any Error).self) {try gate.dispatch {calls.withLock {$0 += 1}}}
        #expect(calls.withLock {$0} == 0)
    }
    @Test func invalidationDoesNotWaitForAnAlreadyStartedWriter() {
        let gate=SNESFirmwareDispatchGate(),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        let finished=DispatchSemaphore(value:0),invalidated=DispatchSemaphore(value:0)
        let result=OSAllocatedUnfairLock(initialState:Optional<Bool>.none)
        Thread.detachNewThread {
            _=try? gate.dispatch {entered.signal();release.wait()}
            finished.signal()
        }
        guard entered.wait(timeout:.now()+30) == .success else {
            release.signal();_=finished.wait(timeout:.now()+30);Issue.record("Writer did not start");return
        }
        Thread.detachNewThread {let stopped=gate.invalidate();result.withLock {$0=stopped};invalidated.signal()}
        let timely=invalidated.wait(timeout:.now()+30) == .success
        release.signal()
        let workerFinished=finished.wait(timeout:.now()+30) == .success
        let invalidatorFinished=timely || invalidated.wait(timeout:.now()+30) == .success
        #expect(timely)
        #expect(workerFinished && invalidatorFinished)
        #expect(result.withLock {$0} == false)
    }
    @Test func invalidationCanWinWhileBoundaryValidationIsBlocked() {
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
        let calls=OSAllocatedUnfairLock(initialState:0)
        let gate=SNESFirmwareDispatchGate(validate:{entered.signal();release.wait()})
        Thread.detachNewThread {_=try? gate.dispatch {calls.withLock {$0 += 1}};finished.signal()}
        guard entered.wait(timeout:.now()+30) == .success else {
            release.signal();_=finished.wait(timeout:.now()+30);Issue.record("Boundary validation did not start");return
        }
        let done=DispatchSemaphore(value:0),stopped=OSAllocatedUnfairLock(initialState:Optional<Bool>.none)
        Thread.detachNewThread {let result=gate.invalidate();stopped.withLock {$0=result};done.signal()}
        let timely=done.wait(timeout:.now()+30) == .success
        release.signal()
        let workerFinished=finished.wait(timeout:.now()+30) == .success
        let invalidatorFinished=timely || done.wait(timeout:.now()+30) == .success
        #expect(timely && stopped.withLock {$0} == true)
        #expect(workerFinished && invalidatorFinished)
        #expect(calls.withLock {$0} == 0)
    }
    @Test func cancelledTaskCannotBeginDispatch() async {
        let gate=SNESFirmwareDispatchGate(),calls=OSAllocatedUnfairLock(initialState:0)
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            try gate.dispatch {calls.withLock {$0 += 1}}
        }
        await #expect(throws:(any Error).self) {try await task.value}
        #expect(calls.withLock {$0} == 0)
    }
    @Test func cancelledReplayCannotEraseTheDispatchedOutcome() async throws {
        let gate=SNESFirmwareDispatchGate()
        try gate.dispatch {}
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            try gate.dispatch {}
        }
        await #expect(throws:(any Error).self) {try await task.value}
        #expect(!gate.invalidate())
    }
    @Test func competingInvalidationAndDispatchHaveOneOutcome() async {
        for _ in 0..<100 {
            let gate=SNESFirmwareDispatchGate(),calls=OSAllocatedUnfairLock(initialState:0)
            async let invalidated=gate.invalidate()
            async let dispatched:Bool = {
                do {try gate.dispatch {calls.withLock {$0 += 1}};return true} catch {return false}
            }()
            let (stopped,started)=await (invalidated,dispatched)
            #expect(stopped != started)
            #expect(calls.withLock {$0} == (started ? 1:0))
        }
    }
}
