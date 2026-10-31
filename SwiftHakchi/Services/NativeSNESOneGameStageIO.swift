import Foundation

actor NativeSNESOneGameStageIO:SNESOneGameStageIO {
    private let material:SNESOneGameMaterial
    private var client:LegacyInspectionClient?
    init(material:SNESOneGameMaterial){self.material=material}
    func inventory()throws->[RecoveryProbeUSBDevice] {try material.validate();return try RecoveryProbeUSBRegistry.inventory()}
    func connect(expected:RecoveryProbeUSBDevice) async throws {
        guard client==nil else {throw LegacyInspectionError.busy}
        try material.validate();_=try SNESStartupTrialUSBPolicy.nativeIdentity(expected)
        guard expected.deviceVersion == (try SNESStartupTrialExpectation.checked(material.accepted.material.trial).deviceVersion) else {throw SNESOneGameMenu.failure()}
        let next=LegacyInspectionClient(transport:SNESStartupTrialUSBTransport(expected:expected),maximumOutputBytes:16384,retainIncompleteOutput:false)
        client=next;try await next.connect(timeoutMilliseconds:10000);try material.validate()
    }
    func report(challenge:UUID) async throws->Data {
        try material.validate();guard let client else {throw LegacyInspectionError.disconnected}
        let result=try await client.readSNESStartupTrial(material.accepted.material.trial,challenge:challenge)
        try material.validate();guard result.succeeded,result.stdoutData.count<=16384 else {throw SNESOneGameMenu.failure()};return result.stdoutData
    }
    private func require(_ value:SNESOneGameMaterial)throws {
        try material.validate();try value.validate()
        guard material.reviewSHA256==value.reviewSHA256 else {throw SNESOneGameMenu.failure()}
    }
    private func output(_ result:SSHResult)throws->Data {
        try material.validate();guard result.succeeded,result.stdoutData.count<=4096 else {throw SNESOneGameMenu.failure()};return result.stdoutData
    }
    func preflight(_ value:SNESOneGameMaterial,challenge:UUID) async throws->Data {
        try require(value);guard let client else {throw LegacyInspectionError.disconnected}
        return try output(await client.preflightSNESOneGame(value,challenge:challenge))
    }
    func inspect(_ value:SNESOneGameMaterial,challenge:UUID) async throws->Data {
        try require(value);guard let client else {throw LegacyInspectionError.disconnected}
        let result=try await client.inspectSNESOneGame(value,challenge:challenge,includeProcesses:true);try material.validate()
        if result.stderr.contains("SWIFTHAKCHI_SNES_PROCESS_DETAILS_V1") {FileHandle.standardError.write(Data(result.stderr.prefix(8192).utf8))}
        guard result.succeeded,result.stdoutData.count<=16384 else {throw SNESOneGameMenu.failure()};return result.stdoutData
    }
    func verify(_ value:SNESOneGameMaterial,challenge:UUID) async throws->Data {
        try require(value);guard let client else {throw LegacyInspectionError.disconnected}
        return try output(await client.verifySNESOneGame(value,challenge:challenge))
    }
    func copy(_ value:SNESOneGameMaterial,permit:SNESOneGameCopyPermit) async throws->Data {
        try require(value);try permit.require(value);guard let client else {throw LegacyInspectionError.disconnected}
        return try output(await client.copySNESOneGame(value,permit:permit))
    }
    func disconnect() async {await client?.disconnect();client=nil}
}
