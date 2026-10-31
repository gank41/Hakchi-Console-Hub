import Foundation

actor NativeSNESOriginalGamesIO: SNESOriginalGamesIO {
    private let trial:PreparedSNESStartupTrial
    private var client:LegacyInspectionClient?
    init(trial:PreparedSNESStartupTrial) {self.trial=trial}
    func inventory() throws -> [RecoveryProbeUSBDevice] {try Task.checkCancellation();return try RecoveryProbeUSBRegistry.inventory()}
    func connect(expected:RecoveryProbeUSBDevice) async throws {
        guard client==nil else {throw LegacyInspectionError.busy}
        try trial.validateCurrent();_=try SNESStartupTrialUSBPolicy.nativeIdentity(expected)
        let next=LegacyInspectionClient(transport:SNESStartupTrialUSBTransport(expected:expected),maximumOutputBytes:SNESOriginalGamesFrame.maximumSize,retainIncompleteOutput:false)
        client=next;try await next.connect(timeoutMilliseconds:10000)
    }
    func report(challenge:UUID) async throws -> Data {
        try trial.validateCurrent();guard let client else {throw LegacyInspectionError.disconnected}
        let value=try await client.readSNESStartupTrial(trial,challenge:challenge)
        guard value.succeeded,value.stdoutData.count<=16384 else {throw SNESOriginalGamesFrame.failure()}
        try trial.validateCurrent();return value.stdoutData
    }
    func originalGames(challenge:UUID) async throws -> Data {
        try trial.validateCurrent();guard let client else {throw LegacyInspectionError.disconnected}
        let value=try await client.readSNESOriginalGames(binding:trial.candidate.material.binding,challenge:challenge)
        guard value.succeeded,value.stdoutData.count<=SNESOriginalGamesFrame.maximumSize else {throw SNESOriginalGamesFrame.failure()}
        try trial.validateCurrent();return value.stdoutData
    }
    func disconnect() async {await client?.disconnect();client=nil}
}
