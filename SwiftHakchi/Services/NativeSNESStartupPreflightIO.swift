import Foundation
import SwiftHakchiCore

/// Only existing trusted RAM recovery is booted. Staged candidate bytes are never executed.
actor NativeSNESStartupPreflightIO:SNESStartupPreflightIO {
    private let candidate:SNESStartupAdapterCandidate,source:SNESPreparationSource,shell:SSHService,base:NativeSNESDataSnapshotIO
    private let parent:SNESMenuStartupParent?
    private var dataChecked=false,stageRequested=false
    private var liveDataSHA256:String?
    init(candidate:SNESStartupAdapterCandidate,parent:SNESMenuStartupParent?=nil) throws {
        guard parent != nil || !candidate.hasMenuSupport else {throw SNESRuntimeBinding.failure()}
        try parent?.require(candidate)
        self.candidate=candidate;self.parent=parent;source=try SNESPreparationSource.load(candidate.material.support.setup)
        let shared=SSHService();shell=shared;base=NativeSNESDataSnapshotIO(source:source,shell:shared)
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] {try await base.inventory()}
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {try await base.boot(inputs,expected:expected)}
    func connect(expected:RecoveryProbeUSBDevice) async throws {dataChecked=false;stageRequested=false;liveDataSHA256=nil;try await base.connect(expected:expected)}
    func observe() async throws -> String {try await base.observe()}
    func readBoot2(_ slot:RecoveryBootSlot) async throws -> RecoveryBoot2Read {try await base.readBoot2(slot)}
    func readBoot1() async throws -> Data {try await base.readBoot1()}
    func readPartitions() async throws -> Data {dataChecked=false;return try await base.readPartitions()}
    func readDataSuperblock() async throws -> Data {dataChecked=false;return try await base.readDataSuperblock()}
    private static func validate(_ candidate:SNESStartupAdapterCandidate,_ parent:SNESMenuStartupParent?)throws {
        try Task.checkCancellation();try candidate.material.revalidate();try candidate.backup.revalidate();try parent?.require(candidate)
    }
    private func validate() throws {try Self.validate(candidate,parent)}
    func dataHash(challenge:UUID) async throws -> Data {
        dataChecked=false;try validate()
        let raw=try await base.dataHash(challenge:challenge);try validate()
        let digest=try SNESDataSnapshotChunk.fullHash(raw,challenge:challenge,count:candidate.backup.byteCount)
        if let liveDataSHA256,liveDataSHA256 != digest {throw SNESStartupPreflightService.dataChanged()}
        liveDataSHA256=digest
        dataChecked=true;return raw
    }
    private func execute(_ command:String,marker:String) async throws {
        try validate()
        let reply=try await shell.executeBounded(command,stdoutLimit:4096,stderrLimit:16384,timeout:30000)
        try validate()
        guard reply.transportCode==0,reply.stderr.count<=16384 else {throw SNESRuntimeBinding.failure()}
        try StockRestoreCompletion.require(.init(stdout:"",stderr:"",stdoutData:reply.stdout,exitCode:reply.exitCode),marker:marker)
    }
    func stageStartup(_ image:Data,stock:Data,id:UUID) async throws {
        try validate()
        guard dataChecked,!stageRequested,image==candidate.image,stock==source.stock else {throw SNESRuntimeBinding.failure()}
        stageRequested=true
        let create=try SNESStartupPreflightCommands.create(id:id,imageBytes:image.count,stockBytes:stock.count)
        let imageSHA=BackupManifest.digest(image),stockSHA=BackupManifest.digest(stock)
        let check=try SNESStartupPreflightCommands.check(id:id,imageBytes:image.count,stockBytes:stock.count,imageSHA:imageSHA,stockSHA:stockSHA)
        let directory=SNESStartupPreflightCommands.directory(id),base=self.base,shell=self.shell,source=self.source,candidate=self.candidate,parent=self.parent
        try await SNESStartupRAMStaging.run(validate:{try Self.validate(candidate,parent)},
            observe:{try source.requireObservation(SNESBackupPolicy.observation(await base.observe()))},
            create:{try await self.execute(create,marker:SNESStartupPreflightCommands.created(id))},
            uploadImage:{try await shell.upload(data:image,to:directory+"/startup.img")},
            uploadStock:{try await shell.upload(data:stock,to:directory+"/stock.img")},
            verify:{try await self.execute(check,marker:SNESStartupPreflightCommands.staged(id,imageSHA:imageSHA,stockSHA:stockSHA))})
    }

    func disconnect() async {dataChecked=false;liveDataSHA256=nil;await base.disconnect()}
}
