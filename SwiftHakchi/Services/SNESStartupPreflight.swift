import Foundation
import SwiftHakchiCore

protocol SNESStartupPreflightIO: RecoveryProbeIO {
    func dataHash(challenge:UUID) async throws -> Data
    func stageStartup(_ image:Data,stock:Data,id:UUID) async throws
}
struct SNESStartupPreflightReceipt: Sendable {
    let record: SNESSetupRecordReceipt
    let backupMatches: Bool
}
struct SNESStartupPreflightResult:Sendable {
    let candidate:SNESStartupAdapterCandidate,context:RecoverySessionContext,id:UUID,header:Data,dataSHA256:String
    let parent:SNESMenuStartupParent?
    fileprivate init(candidate:SNESStartupAdapterCandidate,context:RecoverySessionContext,id:UUID,header:Data,dataSHA256:String,parent:SNESMenuStartupParent?=nil) {
        self.candidate=candidate;self.context=context;self.id=id;self.header=header;self.dataSHA256=dataSHA256;self.parent=parent
    }
    private struct Manifest:Encodable {
        let schemaVersion:Int,scope:String,complete=true
        let parent:SNESMenuStartupParent.Record?
        let firmwareWritten=false,firmwareInstallEligible=false,bootEligible=false,firmwareRestoreEligible=false
        let operationID:UUID,binding:SNESRuntimeBinding,context:SNESDataSnapshotResult.RecoverySessionContextRecord
        let imageSHA256:String,stockSHA256:String,dataSHA256:String,headerSHA256:String,initialBackupDataSHA256:String
        let backupMatchesCheckedData:Bool
        let imageBytes:Int,stockBytes:Int,dataBytes:Int,currentDataBackup:String
    }
    func checkedExport() throws -> (files:[String:Data],manifest:Data) {
        try Task.checkCancellation();try parent?.require(candidate);_=try candidate.checkedExport()
        let source=try SNESPreparationSource.load(candidate.material.support.setup)
        try source.requireObservation(context.observation)
        _=try RecoveryProbePolicy.before([context.before])
        let savedHeader=try RestoreDirectory(candidate.backup.directory).read("data-header.bin",maximum:2048)
        guard try RecoveryProbePolicy.after([context.after],original:context.before)==context.after,SNESDataSnapshotChunk.isDigest(dataSHA256) else { throw SNESRuntimeBinding.failure() }
        _=try source.validateHeader(Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8)+header)
        let m=Manifest(schemaVersion:parent==nil ? 1:2,scope:parent==nil ? "snes-startup-no-flash-preflight":"snes-menu-startup-no-flash-preflight",parent:parent?.record,operationID:id,binding:materialBinding,context:.init(context),imageSHA256:BackupManifest.digest(candidate.image),
            stockSHA256:BackupManifest.digest(source.stock),dataSHA256:dataSHA256,headerSHA256:BackupManifest.digest(header),
            initialBackupDataSHA256:candidate.backup.sha256,backupMatchesCheckedData:header==savedHeader && dataSHA256==candidate.backup.sha256,
            imageBytes:candidate.image.count,stockBytes:source.stock.count,dataBytes:candidate.backup.byteCount,currentDataBackup:candidate.backup.directory.lastPathComponent)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let manifest=try encoder.encode(m);try parent?.validate()
        return (["data-header.bin":header],manifest)
    }
    private var materialBinding:SNESRuntimeBinding { candidate.material.binding }
    func backupMatches() throws -> Bool {
        try candidate.backup.revalidate()
        let saved = try RestoreDirectory(candidate.backup.directory).read("data-header.bin", maximum: 2048)
        return header == saved && dataSHA256 == candidate.backup.sha256
    }
}
private actor SNESStartupPreflightConnection:SNESStartupPreflightIO {
    let base:any SNESStartupPreflightIO
    private let validate:@Sendable ()throws->Void
    private var closed=false
    init(_ base:any SNESStartupPreflightIO,validate:@escaping @Sendable ()throws->Void) {self.base=base;self.validate=validate}
    private func checked<Value:Sendable>(_ action:@Sendable ()async throws->Value) async throws->Value {
        try validate();let value=try await action();try validate();return value
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] {try await checked {try await self.base.inventory()}}
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {try await checked {try await self.base.boot(inputs,expected:expected)}}
    func connect(expected:RecoveryProbeUSBDevice) async throws {try await checked {try await self.base.connect(expected:expected)}}
    func observe() async throws -> String {try await checked {try await self.base.observe()}}
    func readBoot2(_ slot:RecoveryBootSlot) async throws -> RecoveryBoot2Read {try await checked {try await self.base.readBoot2(slot)}}
    func readBoot1() async throws -> Data {try await checked {try await self.base.readBoot1()}}
    func readPartitions() async throws -> Data {try await checked {try await self.base.readPartitions()}}
    func readDataSuperblock() async throws -> Data {try await checked {try await self.base.readDataSuperblock()}}
    func dataHash(challenge:UUID) async throws -> Data {try await checked {try await self.base.dataHash(challenge:challenge)}}
    func stageStartup(_ image:Data,stock:Data,id:UUID) async throws {try await checked {try await self.base.stageStartup(image,stock:stock,id:id)}}
    func disconnect() async {guard !closed else{return};closed=true;await base.disconnect()}
}
actor SNESStartupPreflightService {
    private let session:RecoverySessionCoordinator
    private var busy=false
    init(wait:@escaping @Sendable () async throws -> Void={ try await Task.sleep(for:.seconds(1)) }) {session=RecoverySessionCoordinator(wait:wait)}
    func capture(candidate:SNESStartupAdapterCandidate,inputs:RecoveryBootInputs,io:any SNESStartupPreflightIO,
                 progress:@escaping RecoveryProgressSink={_ in},parent:SNESMenuStartupParent?=nil) async throws -> SNESStartupPreflightResult {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
        guard parent != nil || !candidate.hasMenuSupport else {throw SNESRuntimeBinding.failure()}
        let validate:@Sendable () throws -> Void={try Task.checkCancellation();try candidate.material.revalidate();try candidate.backup.revalidate();try parent?.require(candidate)}
        try validate();_=try candidate.checkedExport()
        let source=try SNESPreparationSource.load(candidate.material.support.setup),expectedActive=parent?.activeImage ?? source.stock,connection=SNESStartupPreflightConnection(io,validate:validate),id=UUID()
        do {
            let (context,value)=try await session.run(inputs:inputs,io:connection,progress:progress,validateObservation:{
                let observation=try SNESBackupPolicy.observation($0);try source.requireObservation(observation);return observation
            }) { context in
                try validate();await progress(.readingCurrentKernel);try validate()
                for _ in 0..<2 {
                    guard case .image(let bytes)=try await connection.readBoot2(.active),bytes==expectedActive else {throw SNESRuntimeBinding.failure()};try validate()
                }
                await progress(.readingBootloader);try validate()
                guard try await connection.readBoot1()==source.boot1 else {throw SNESRuntimeBinding.failure()};try validate()
                await progress(.checkingPartitions);try validate()
                guard try await connection.readPartitions()==source.partitions else {throw SNESRuntimeBinding.failure()};try validate()
                let header=try source.validateHeader(await connection.readDataSuperblock());try validate()
                let first=UUID(),hash=try await connection.dataHash(challenge:first);try validate()
                let expectedHash=try SNESDataSnapshotChunk.fullHash(hash,challenge:first,count:candidate.backup.byteCount)
                let before=try SNESBackupPolicy.observation(await connection.observe());try validate()
                guard before.hwid==context.observation.hwid,before.mounts==context.observation.mounts,
                      try await connection.inventory()==[context.after] else {throw SNESRuntimeBinding.failure()};try validate()
                await progress(.stagingStock);try validate()
                try await connection.stageStartup(candidate.image,stock:source.stock,id:id);try validate()
                await progress(.verifying);try validate()
                guard try await connection.inventory()==[context.after] else {throw SNESRuntimeBinding.failure()};try validate()
                let final=UUID(),last=try await connection.dataHash(challenge:final);try validate()
                guard try SNESDataSnapshotChunk.fullHash(last,challenge:final,count:candidate.backup.byteCount)==expectedHash else {throw Self.dataChanged()}
                guard try source.validateHeader(await connection.readDataSuperblock())==header,
                      try await connection.readPartitions()==source.partitions else {throw SNESRuntimeBinding.failure()};try validate()
                let after=try SNESBackupPolicy.observation(await connection.observe());try validate()
                guard after.hwid==context.observation.hwid,after.mounts==context.observation.mounts,
                      try await connection.inventory()==[context.after] else {throw SNESRuntimeBinding.failure()};try validate()
                return (header,expectedHash)
            }
            try validate();return .init(candidate:candidate,context:context,id:id,header:value.0,dataSHA256:value.1,parent:parent)
        } catch {await connection.disconnect();throw error}
    }
    static func dataChanged() -> RecoveryProbeError {
        .refused("The console data changed during the memory-only check. Nothing was installed; the check did not complete.")
    }
}
