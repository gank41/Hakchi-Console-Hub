import Foundation

actor NativeSNESDataSnapshotIO: SNESDataSnapshotIO {
    private let shell:SSHService, recovery:NativeRecoveryProbeIO, source:SNESPreparationSource
    private var partitionsChecked=false, headerChecked=false
    init(source:SNESPreparationSource,shell:SSHService=SSHService()) {
        self.source=source
        self.shell=shell
        recovery=NativeRecoveryProbeIO(shell:shell,observationCommand:SNESBackupPolicy.command)
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await recovery.inventory() }
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws { try await recovery.boot(inputs,expected:expected) }
    func connect(expected:RecoveryProbeUSBDevice) async throws { partitionsChecked=false; headerChecked=false; try await recovery.connect(expected:expected) }
    func observe() async throws -> String { try await recovery.observe() }
    func readBoot2(_ slot:RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await recovery.readBoot2(slot) }
    func readBoot1() async throws -> Data { try await recovery.readBoot1() }
    func readPartitions() async throws -> Data {
        partitionsChecked=false; headerChecked=false
        let raw=try await recovery.readPartitions()
        guard raw==source.partitions else { throw SNESDataSnapshotError.refused }
        partitionsChecked=true; return raw
    }
    func readDataSuperblock() async throws -> Data {
        guard partitionsChecked else { throw SNESDataSnapshotError.refused }; headerChecked=false
        let raw=try await recovery.readDataSuperblock(); _=try source.validateHeader(raw)
        headerChecked=true; return raw
    }
    private func read(_ command:String,limit:Int,timeout:Int) async throws -> Data {
        try Task.checkCancellation(); try source.revalidate()
        guard partitionsChecked,headerChecked else { throw SNESDataSnapshotError.refused }
        try source.requireObservation(SNESBackupPolicy.observation(await recovery.observe()))
        let result=try await shell.executeBounded(command,stdoutLimit:limit,stderrLimit:16384,timeout:timeout)
        try Task.checkCancellation(); try source.revalidate()
        guard result.transportCode==0,result.exitCode==0,result.stdout.count<=limit,result.stderr.count<=16384 else { throw SNESDataSnapshotError.refused }
        return result.stdout
    }
    func dataHash(challenge:UUID) async throws -> Data {
        let plan=try source.dataSnapshotPlan()
        return try await read(SNESDataSnapshotCommands.hash(plan:plan,challenge:challenge),limit:256,timeout:180000)
    }
    func dataChunk(index:Int,challenge:UUID) async throws -> Data {
        let plan=try source.dataSnapshotPlan(), count=try plan.range(index).count
        return try await read(SNESDataSnapshotCommands.read(plan:plan,index:index,challenge:challenge),limit:count+512,timeout:180000)
    }
    func disconnect() async { partitionsChecked=false; headerChecked=false; await recovery.disconnect() }
}
