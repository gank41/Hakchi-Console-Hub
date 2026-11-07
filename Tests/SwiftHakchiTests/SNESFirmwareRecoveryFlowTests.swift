import Testing
@testable import SwiftHakchi

@MainActor struct SNESFirmwareRecoveryFlowTests {
    @Test func uncertainUpdateRequiresReadinessAndNeverAutomaticallyRepeats() async throws {
        var calls = 0
        for phase: SNESFirmwareJournal.Phase in [.prepared, .preflightVerified, .readbackVerified, .startupVerified, .menuAccepted] {
            #expect(throws: (any Error).self) { try SNESFirmwareRecoveryFlow(phase: phase, inspect: { .target }) }
        }
        let flow = try SNESFirmwareRecoveryFlow(phase: .uncertain, inspect: { calls += 1; return .target })
        await flow.inspect(ready: false); #expect(calls == 0 && flow.phase == .ready)
        await flow.inspect(ready: true); await flow.inspect(ready: true)
        #expect(calls == 1 && flow.phase == .complete && flow.result == .target)
    }

    @Test func failedInspectionDoesNotClaimAResultOrRetry() async throws {
        var calls = 0
        let flow = try SNESFirmwareRecoveryFlow(phase: .writeIntent, inspect: { calls += 1; throw RecoveryProbeError.refused("Read failed") })
        await flow.inspect(ready: true); await flow.inspect(ready: true)
        #expect(calls == 1 && flow.phase == .failed && flow.result == nil && flow.error != nil)
    }
}
