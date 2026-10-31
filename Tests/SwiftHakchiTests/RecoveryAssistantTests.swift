import Foundation
import Testing
@testable import SwiftHakchi

private actor AssistantCalls {
    var actions: [RecoveryAssistantAction] = []
    let result: RecoveryAssistantResult
    init(_ result: RecoveryAssistantResult) { self.result = result }
    func run(_ action: RecoveryAssistantAction, _ progress: RecoveryProgressSink) async throws -> RecoveryAssistantResult {
        actions.append(action); await progress(.checkingMaterial); return result
    }
}
private func assistantReview(_ phase: StockRestoreJournal.Phase) -> RecoveryAssistantReview {
    .init(operationDirectory:"/tmp/StockKernelRestore-test",reviewSHA256:String(repeating:"a",count:64),phase:phase,
          stockBytes:2826240,stockSHA256:String(repeating:"b",count:64),preimageBytes:3788800,preimageSHA256:String(repeating:"c",count:64))
}
@MainActor
struct RecoveryAssistantTests {
    @Test func legacyWriteReviewIsBoundToTheSameOperationAndRequiresMenuReturn() async {
        let a = LegacyRecoveryAssistantReview(operationDirectory: "/tmp/LegacyBoot2Activation-a",
            reviewSHA256: String(repeating: "a", count: 64), phase: .preflightVerified,
            stockBytes: 2_826_240, stockSHA256: LegacyBoot2ActivationPlan.stockSHA256,
            legacyBytes: 3_788_800, legacySHA256: LegacyBoot2ActivationPlan.legacySHA256)
        let b = LegacyRecoveryAssistantReview(operationDirectory: "/tmp/LegacyBoot2Activation-b",
            reviewSHA256: String(repeating: "b", count: 64), phase: .preflightVerified,
            stockBytes: a.stockBytes, stockSHA256: a.stockSHA256,
            legacyBytes: a.legacyBytes, legacySHA256: a.legacySHA256)
        let calls = AssistantCalls(.legacyReview(a))
        let model = RecoveryAssistantModel(execute: { action, progress in
            if case .legacyInspect(let value) = action { return .legacyReview(value) }
            return try await calls.run(action, progress)
        })
        await model.perform(.legacyInspect(a))
        #expect(model.normalBootPending && !model.canWriteLegacy)
        await model.confirmNormalBoot()
        model.acknowledgeLegacyWriteReview(true, for: a)
        #expect(model.canWriteLegacy)
        await model.perform(.legacyInspect(b))
        await model.confirmNormalBoot()
        #expect(!model.canWriteLegacy)
        await model.perform(.legacyWrite(b), ready: true)
        #expect(await calls.actions.isEmpty)
        model.acknowledgeLegacyWriteReview(true, for: b)
        #expect(model.canWriteLegacy)
    }
    @Test func launchAndReadinessNeverDispatchHardware() async {
        let calls = AssistantCalls(.snapshot(URL(fileURLWithPath:"/tmp/snapshot")))
        let model = RecoveryAssistantModel(execute:{ try await calls.run($0,$1) })
        #expect(await calls.actions.isEmpty)
        await model.perform(.snapshot(URL(fileURLWithPath:"/tmp")),ready:false)
        #expect(await calls.actions.isEmpty && !model.busy)
    }
    @Test func installEvidenceRequiresReadinessAndReportsItsDistinctScope() async {
        let calls = AssistantCalls(.snapshot(URL(fileURLWithPath:"/tmp/InstallEvidence-test")))
        let model = RecoveryAssistantModel(execute:{ try await calls.run($0,$1) })
        let action = RecoveryAssistantAction.installEvidence(URL(fileURLWithPath:"/tmp"))
        #expect(action.isHardware && !action.isWrite)
        await model.perform(action,ready:false)
        #expect(await calls.actions.isEmpty)
        await model.perform(action,ready:true)
        #expect(await calls.actions.count == 1)
        #expect(model.normalBootPending && model.snapshotURL?.lastPathComponent == "InstallEvidence-test")
        #expect(model.status.localizedCaseInsensitiveContains("boot1"))
        #expect(RecoveryStage.readingBootloader.title.contains("boot1"))
        await model.confirmNormalBoot()
        #expect(!model.normalBootPending)
        #expect(model.status.localizedCaseInsensitiveContains("native installer"))
        #expect(!model.status.localizedCaseInsensitiveContains("prepare a restore"))
    }
    @Test func demonstrationNeverDispatchesAnAction() async {
        let calls = AssistantCalls(.snapshot(URL(fileURLWithPath:"/tmp/snapshot")))
        let model = RecoveryAssistantModel(demonstration:true,execute:{ try await calls.run($0,$1) })
        await model.perform(.snapshot(URL(fileURLWithPath:"/tmp")),ready:true)
        await model.perform(.prepare(snapshot:URL(fileURLWithPath:"/tmp/snapshot"),
                                     stock:URL(fileURLWithPath:"/tmp/stock"),
                                     journals:URL(fileURLWithPath:"/tmp/journals")))
        #expect(await calls.actions.isEmpty && !model.busy && model.demonstration)
    }
    @Test func phasesGateWritesAndPreflightRequiresSeparateAction() async {
        let review = assistantReview(.prepared), calls = AssistantCalls(.review(assistantReview(.preflightVerified)))
        let model = RecoveryAssistantModel(execute:{ try await calls.run($0,$1) })
        await model.perform(.inspect(review))
        #expect(!model.canWrite)
        await model.perform(.write(review),ready:true)
        #expect(await calls.actions.count == 1)
    }
    @Test func preflightRequiresNormalMenuAcknowledgementBeforeWrite() async {
        let prepared = assistantReview(.prepared), passed = assistantReview(.preflightVerified)
        let calls = AssistantCalls(.review(prepared))
        let model = RecoveryAssistantModel(execute:{ action,progress in
            if case .preflight = action { await progress(.checkingPartitions); return .review(passed) }
            return try await calls.run(action,progress)
        })
        await model.perform(.inspect(prepared))
        await model.perform(.preflight(prepared),ready:true)
        #expect(model.normalBootPending && !model.canWrite)
        await model.confirmNormalBoot()
        #expect(!model.normalBootPending && !model.canWrite && model.writeEligible)
        model.acknowledgeWriteReview(true,for:passed)
        #expect(model.canWrite)
        #expect(await calls.actions.count == 1)
    }
    @Test func readbackNeedsExplicitHumanAttestation() async {
        let review = assistantReview(.readbackVerified), calls = AssistantCalls(.review(assistantReview(.menuAccepted)))
        let model = RecoveryAssistantModel(execute:{ action,progress in
            if case .inspect = action { return .review(review) }
            return try await calls.run(action,progress)
        })
        await model.perform(.inspect(review))
        #expect(model.normalBootPending && !model.canWrite)
        #expect(await calls.actions.isEmpty)
        await model.confirmNormalBoot()
        #expect(model.review?.phase == .menuAccepted && !model.normalBootPending)
        #expect(await calls.actions.count == 1)
    }
    @Test func writeReviewDoesNotCarryToAnotherOperationInSamePhase() async {
        let a = assistantReview(.preflightVerified)
        let b = RecoveryAssistantReview(operationDirectory:"/tmp/StockKernelRestore-other",reviewSHA256:String(repeating:"d",count:64),
                                        phase:.preflightVerified,stockBytes:a.stockBytes,stockSHA256:a.stockSHA256,
                                        preimageBytes:a.preimageBytes,preimageSHA256:a.preimageSHA256)
        let calls = AssistantCalls(.review(a))
        let model = RecoveryAssistantModel(execute:{ action,progress in
            if case .inspect(let value) = action { return .review(value) }
            return try await calls.run(action,progress)
        })
        await model.perform(.inspect(a)); await model.confirmNormalBoot()
        model.acknowledgeWriteReview(true,for:a)
        #expect(model.canWrite)
        await model.perform(.inspect(b)); await model.confirmNormalBoot()
        #expect(!model.canWrite)
        await model.perform(.write(b),ready:true)
        #expect(await calls.actions.isEmpty)
        model.acknowledgeWriteReview(true,for:b)
        #expect(model.canWrite)
    }
    @Test func failedWriteNeverOffersRetryOrPowerCycle() async {
        let review = assistantReview(.preflightVerified)
        let model = RecoveryAssistantModel(execute:{ action,_ in
            if case .inspect = action { return .review(review) }
            throw RecoveryProbeError.refused("Lost connection HWID=0123456789abcdef0123456789abcdef")
        })
        await model.perform(.inspect(review)); await model.confirmNormalBoot()
        model.acknowledgeWriteReview(true,for:review)
        await model.perform(.write(review),ready:true)
        #expect(model.requiresPreservedPower && !model.canWrite && !model.normalBootPending)
        #expect(!model.activity.details.contains("0123456789abcdef0123456789abcdef"))
    }
    @Test func uncertainJournalIsReviewOnly() async {
        let review = assistantReview(.uncertain)
        let model = RecoveryAssistantModel(execute:{ _,_ in .review(review) })
        await model.perform(.inspect(review))
        #expect(model.requiresPreservedPower && !model.canWrite && !model.canPreflight)
    }
}

private actor AssistantGate {
    var calls = 0
    var continuation: CheckedContinuation<Void,Never>?
    func wait() async { calls += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
extension RecoveryAssistantTests {
    @Test(.timeLimit(.minutes(1))) func overlappingActionsNeverDispatchTwice() async {
        let gate = AssistantGate()
        let model = RecoveryAssistantModel(execute:{ _,_ in await gate.wait(); return .snapshot(URL(fileURLWithPath:"/tmp/new")) })
        let first = Task { await model.perform(.snapshot(URL(fileURLWithPath:"/tmp")),ready:true) }
        while await gate.calls == 0 { await Task.yield() }
        await model.perform(.snapshot(URL(fileURLWithPath:"/tmp")),ready:true)
        #expect(await gate.calls == 1 && model.busy)
        await gate.release(); await first.value
        #expect(!model.busy && model.normalBootPending)
    }
}
