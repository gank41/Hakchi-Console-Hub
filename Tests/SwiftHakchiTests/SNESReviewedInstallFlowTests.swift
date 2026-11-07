import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct SNESReviewedInstallFlowTests {
    @Test func confirmedWrittenInstallResumesAtNormalStartupCheck() throws {
        #expect(try SNESReviewedInstallFlow.resumePhase(for: .readbackVerified) == .restart)
        #expect(try SNESReviewedInstallFlow.resumePhase(for: .startupVerified) == .restart)
        for phase: SNESFirmwareJournal.Phase in [.prepared, .writeIntent, .uncertain, .menuAccepted] {
            #expect(throws: (any Error).self) { try SNESReviewedInstallFlow.resumePhase(for: phase) }
        }
    }
    @Test func installRequiresApprovalAndRecordsOnlyAConfirmedGame() async {
        var writes=0, checks=0, accepts=0
        let flow=SNESReviewedInstallFlow(install:{ _ in writes += 1 },checkMenu:{ checks += 1 },accept:{ accepts += 1 })
        await flow.install(ready:false,approved:true)
        await flow.install(ready:true,approved:false)
        #expect(writes == 0 && flow.phase == .ready)
        await flow.install(ready:true,approved:true)
        #expect(writes == 1 && flow.phase == .restart)
        await flow.checkMenu(visible:false)
        #expect(checks == 0 && flow.phase == .restart)
        await flow.checkMenu(visible:true)
        #expect(checks == 1 && flow.phase == .gameTest)
        await flow.confirmGame(works:true)
        #expect(accepts == 1 && flow.phase == .firstStageComplete)
        await flow.install(ready:true,approved:true)
        #expect(writes == 1)
    }

    @Test func uncertainWriteOrFailedGameCannotBeMarkedComplete() async {
        var accepts=0
        let uncertain=SNESReviewedInstallFlow(install:{ _ in throw SNESFirmwareTransactionError.uncertain },checkMenu:{},accept:{ accepts += 1 })
        await uncertain.install(ready:true,approved:true)
        #expect(uncertain.phase == .uncertain)
        await uncertain.checkMenu(visible:true); await uncertain.confirmGame(works:true)
        #expect(accepts == 0 && uncertain.phase == .uncertain)
        let failedGame=SNESReviewedInstallFlow(install:{ _ in },checkMenu:{},accept:{ accepts += 1 })
        await failedGame.install(ready:true,approved:true); await failedGame.checkMenu(visible:true)
        await failedGame.confirmGame(works:false)
        #expect(accepts == 0 && failedGame.phase == .needsAttention)
        let failedMenu=SNESReviewedInstallFlow(install:{ _ in },checkMenu:{},accept:{ accepts += 1 })
        await failedMenu.install(ready:true,approved:true); failedMenu.reportMenuProblem()
        await failedMenu.checkMenu(visible:true)
        #expect(accepts == 0 && failedMenu.phase == .needsAttention)
    }

    @Test func stoppedWriteDoesNotAutomaticallyRetry() async {
        var attempts=0
        let flow=SNESReviewedInstallFlow(install:{ _ in attempts += 1; throw RecoveryProbeError.refused("Stopped before writing.") },checkMenu:{},accept:{})
        await flow.install(ready:true,approved:true)
        await flow.install(ready:true,approved:true)
        #expect(attempts == 1 && flow.phase == .stopped)
    }

    @Test func anUncertainSavedConfirmationIsNotRepeatedAutomatically() async {
        var attempts=0
        let flow=SNESReviewedInstallFlow(install:{ _ in },checkMenu:{},accept:{ attempts += 1; throw RecoveryProbeError.refused("Could not confirm the saved record.") })
        await flow.install(ready:true,approved:true); await flow.checkMenu(visible:true)
        await flow.confirmGame(works:true); await flow.confirmGame(works:true)
        #expect(attempts == 1 && flow.phase == .needsAttention)
    }

    @Test func aSecondClickCannotStartAnotherWriteWhileTheFirstIsRunning() async {
        var writes=0, continuation:CheckedContinuation<Void,Never>?
        let flow=SNESReviewedInstallFlow(install:{ _ in
            try Task.checkCancellation(); writes += 1; await withCheckedContinuation { continuation = $0 }
        },checkMenu:{},accept:{})
        let first=Task { await flow.install(ready:true,approved:true) }
        for _ in 0..<1000 { if continuation != nil { break }; await Task.yield() }
        guard let continuation else { first.cancel(); Issue.record("The simulated update did not start."); return }
        await flow.install(ready:true,approved:true)
        #expect(writes == 1 && flow.phase == .writing)
        continuation.resume(); await first.value
        #expect(writes == 1 && flow.phase == .restart)
    }

    @Test func failedNormalStartupCheckCannotAcceptTheInstallation() async {
        var accepts=0
        let flow=SNESReviewedInstallFlow(install:{ _ in },checkMenu:{ throw RecoveryProbeError.refused("The menu could not be verified.") },accept:{ accepts += 1 })
        await flow.install(ready:true,approved:true); await flow.checkMenu(visible:true); await flow.confirmGame(works:true)
        #expect(accepts == 0 && flow.phase == .needsAttention)
    }
}
