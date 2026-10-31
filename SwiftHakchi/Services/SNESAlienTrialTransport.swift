import Foundation

actor NativeSNESAlienTrialIO: SNESAlienTrialIO {
    private let trial: PreparedSNESAlienTrial
    private var client: LegacyInspectionClient?
    init(trial: PreparedSNESAlienTrial) { self.trial = trial }
    func inventory() throws -> [RecoveryProbeUSBDevice] { try Task.checkCancellation(); return try RecoveryProbeUSBRegistry.inventory() }
    func boot(expected: RecoveryProbeUSBDevice) async throws {
        try trial.validateCurrent()
        let fel = FELService(makeSession: { IOKitFELSessionTransport(expected: expected) })
        try await fel.memboot(alienTrial: trial)
    }
    func connect(expected: RecoveryProbeUSBDevice) async throws {
        try trial.validateCurrent(); _ = try SNESOriginalMenuUSBPolicy.nativeIdentity(expected)
        guard client == nil else { throw LegacyInspectionError.busy }
        let next = LegacyInspectionClient(transport: SNESOriginalMenuUSBTransport(expected: expected), maximumOutputBytes: 65536, retainIncompleteOutput: true)
        client = next; try await next.connect(timeoutMilliseconds: 10_000)
    }
    private func perform(_ operation: @Sendable (LegacyInspectionClient) async throws -> SSHResult) async throws -> Data {
        try Task.checkCancellation(); try trial.validateCurrent()
        guard let client else { throw LegacyInspectionError.disconnected }
        let result = try await operation(client)
        guard result.succeeded, result.stdoutData.count <= 65536 else { throw SNESRuntimeBinding.failure() }
        return result.stdoutData
    }
    func checkpoint(challenge: UUID) async throws -> Data {
        let trial = trial
        return try await perform { try await $0.checkpointSNESAlienTrial(trial, challenge: challenge) }
    }
    func launch(_ request: SNESAlienTrialLaunchRequest) async throws {
        let response = try await perform { try await $0.launchSNESAlienTrial(request) }
        guard response == request.acknowledgement else { throw SNESRuntimeBinding.failure() }
    }
    func report(challenge: UUID) async throws -> Data {
        try await perform { try await $0.execute(.snesAlienTrialReport(challenge: challenge), timeoutMilliseconds: 75_000) }
    }
    func diagnostics() async throws -> Data {
        try await perform { try await $0.execute(.snesOriginalMenuDiagnostics, timeoutMilliseconds: 10_000) }
    }
    func disconnect() async { await client?.disconnect(); client = nil }
}
