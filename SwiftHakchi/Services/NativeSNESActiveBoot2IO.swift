import Foundation

/// Trusted recovery and a source-owned read-only helper; no write/burn API.
actor NativeSNESActiveBoot2IO:SNESActiveBoot2IO {
    private let source:SNESPreparationSource,helper:SNESBoundedReadHelper,shell:SSHService,base:NativeSNESDataSnapshotIO
    private var ready=false,staged=false,stageRequested=false,id=UUID()
    init(source:SNESPreparationSource,helper:SNESBoundedReadHelper,shell:SSHService?=nil) {
        self.source=source;self.helper=helper;let shared=shell ?? SSHService();self.shell=shared;base=NativeSNESDataSnapshotIO(source:source,shell:shared)
    }
    func inventory() async throws->[RecoveryProbeUSBDevice] {try await base.inventory()}
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {try await base.boot(inputs,expected:expected)}
    func connect(expected:RecoveryProbeUSBDevice) async throws {ready=false;staged=false;stageRequested=false;id=UUID();try await base.connect(expected:expected)}
    func observe() async throws->String {try await base.observe()}
    func readBoot2(_ slot:RecoveryBootSlot) async throws->RecoveryBoot2Read {try await base.readBoot2(slot)}
    func readBoot1() async throws->Data {try await base.readBoot1()}
    func readPartitions() async throws->Data {ready=false;return try await base.readPartitions()}
    func readDataSuperblock() async throws->Data {ready=false;let raw=try await base.readDataSuperblock();_=try source.validateHeader(raw);ready=true;return raw}
    private func validate()throws {try Task.checkCancellation();try source.revalidate();try helper.revalidate()}
    private func execute(_ command:String,limit:Int,timeout:Int) async throws->Data {
        try validate()
        guard ready else {throw SNESRuntimeBinding.failure()}
        try source.requireObservation(SNESBackupPolicy.observation(await base.observe()));try validate()
        let result=try await shell.executeBounded(command,stdoutLimit:limit,stderrLimit:16384,timeout:timeout)
        try validate()
        guard result.transportCode==0,result.exitCode==0,result.stdout.count<=limit,result.stderr.count<=16384 else {
            let detail="Read-only startup command failed: transport=\(result.transportCode), exit=\(result.exitCode), stderr="+String(decoding:result.stderr.prefix(1024),as:UTF8.self)
            throw SNESActiveBoot2ReadFailure(partial:Data(result.stdout.prefix(16384)),reason:detail)
        }
        return result.stdout
    }
    private func ensureStaged() async throws {
        if staged {return}
        guard ready,!stageRequested else {throw SNESRuntimeBinding.failure()};stageRequested=true
        let first=try await execute(SNESActiveBoot2Commands.create(id:id),limit:256,timeout:30000)
        guard first==Data(SNESActiveBoot2Commands.created(id).utf8) else {throw SNESRuntimeBinding.failure()}
        try validate();try await shell.upload(data:helper.bytes,to:SNESActiveBoot2Commands.directory(id)+"/reader");try validate()
        let second=try await execute(SNESActiveBoot2Commands.validation(id:id,helper:helper),limit:256,timeout:30000)
        guard second==Data(SNESActiveBoot2Commands.checked(id).utf8) else {throw SNESRuntimeBinding.failure()}
        staged=true
    }
    private func read(_ kind:SNESPhysicalFrame.Kind,challenge:UUID) async throws->Data {
        try validate();try await ensureStaged();try validate()
        return try await execute(SNESActiveBoot2Commands.read(id:id,kind:kind,challenge:challenge,helper:helper),limit:kind.count+512,timeout:180000)
    }
    func geometry(challenge:UUID) async throws->Data {try await read(.geometry,challenge:challenge)}
    func readActive(challenge:UUID) async throws->Data {try await read(.active,challenge:challenge)}
    func disconnect() async {ready=false;staged=false;await base.disconnect()}
}
