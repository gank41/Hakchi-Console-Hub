import Foundation

struct RecoverySessionContext: Sendable {
    let before: RecoveryProbeUSBDevice
    let after: RecoveryProbeUSBDevice
    let observation: RecoveryProbeObservation
}
/// One exact FEL attachment, one accepted RNDIS session, and one guaranteed close.
actor RecoverySessionCoordinator {
    private var busy = false
    private let wait: @Sendable () async throws -> Void
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) { self.wait = wait }
    func run<Value: Sendable>(inputs: RecoveryBootInputs, io: any RecoveryProbeIO, pollLimit: Int = 60, progress: @escaping RecoveryProgressSink = { _ in },
        validateObservation: @Sendable (String) throws -> RecoveryProbeObservation = { try RecoveryProbePolicy.observation($0) },
        action: @Sendable (RecoverySessionContext) async throws -> Value) async throws -> (RecoverySessionContext, Value) {
        guard !busy else { throw RecoveryProbeError.refused("A recovery session is already running.") }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        _ = try inputs.prepare()
        guard (1...60).contains(pollLimit) else { throw RecoveryProbeError.refused("Invalid probe poll limit.") }
        await progress(.checkingUSB)
        let original = try RecoveryProbePolicy.before(await io.inventory())
        try Task.checkCancellation()
        await progress(.uploadingRecovery)
        try await io.boot(inputs, expected: original) // Exactly once; an error can mean execution outcome is uncertain.
        await progress(.waitingForRecovery)
        var appeared: RecoveryProbeUSBDevice?
        for _ in 0..<pollLimit {
            try Task.checkCancellation()
            appeared = try RecoveryProbePolicy.after(await io.inventory(), original: original)
            if appeared != nil { break }
            try await wait()
        }
        guard let appeared else { throw RecoveryProbeError.refused("Timed out waiting for recovery USB. Boot was not retried; power-cycle normally when instructed.") }
        try Task.checkCancellation()
        guard try RecoveryProbePolicy.after(await io.inventory(), original: original) == appeared else {
            throw RecoveryProbeError.refused("Recovery USB changed before SSH open.")
        }
        do {
            try Task.checkCancellation()
            try await io.connect(expected: appeared)
            try Task.checkCancellation()
            await progress(.checkingIdentity)
            let text = try await io.observe()
            try Task.checkCancellation()
            let observation = try validateObservation(text)
            let context = RecoverySessionContext(before: original, after: appeared, observation: observation)
            let result = try await action(context)
            try Task.checkCancellation()
            await progress(.closing)
            await io.disconnect()
            return (context, result)
        } catch { await io.disconnect(); throw error }
    }
}
