import Foundation
import SwiftHakchiCore

protocol SNESActiveBoot2IO:RecoveryProbeIO {
    func geometry(challenge:UUID) async throws -> Data
    func readActive(challenge:UUID) async throws -> Data
}
struct SNESActiveBoot2Snapshot:Sendable {
    let source:SNESPreparationSource,helper:SNESBoundedReadHelper,context:RecoverySessionContext
    let geometry:SNESPhysicalGeometry,header:Data,active:Data,challenges:[UUID]
    fileprivate init(source:SNESPreparationSource,helper:SNESBoundedReadHelper,context:RecoverySessionContext,geometry:SNESPhysicalGeometry,header:Data,active:Data,challenges:[UUID]) {
        self.source=source;self.helper=helper;self.context=context;self.geometry=geometry;self.header=header;self.active=active;self.challenges=challenges
    }
    func checkedExport()throws->(files:[String:Data],manifest:Data) {
        try Task.checkCancellation();try source.revalidate();try helper.revalidate();try source.requireObservation(context.observation)
        _=try SNESBoot2Bounds(partitions:source.partitions)
        guard try RecoveryProbePolicy.after([context.after],original:context.before)==context.after,
              active.count==7340032,active.prefix(source.stock.count)==source.stock,
              challenges.count==4,Set(challenges).count==4 else {throw SNESRuntimeBinding.failure()}
        _=try SNESPhysicalGeometry(geometry.raw)
        _=try source.validateHeader(Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8)+header)
        struct Manifest:Encodable {
            let schemaVersion=1,scope="snes-active-boot2-preimage",complete=true
            let firmwareWritten=false,firmwareInstallEligible=false,firmwareRestoreEligible=false,bootEligible=false
            let binding:SNESRuntimeBinding,context:SNESDataSnapshotResult.RecoverySessionContextRecord
            let sourcePath:String,sourceManifestSHA256:String,helperSHA256:String,stockImageSHA256:String,boot1SHA256:String,partitionsSHA256:String
            let offsetBytes:Int,byteCount:Int,unitBytes:Int,pageSize:UInt32,pagesPerBlock:UInt32,blockCount:UInt32
            let challenges:[UUID],files:[String:String]
        }
        let files=["active-range.bin":active,"geometry.bin":geometry.raw,"data-header.bin":header]
        let m=Manifest(binding:source.source.runtimeBinding,context:.init(context),sourcePath:source.source.directoryURL.path,
            sourceManifestSHA256:source.source.manifestSHA256,helperSHA256:helper.digest,
            stockImageSHA256:BackupManifest.digest(source.stock),boot1SHA256:BackupManifest.digest(source.boot1),partitionsSHA256:BackupManifest.digest(source.partitions),
            offsetBytes:0x600000,byteCount:active.count,unitBytes:131072,pageSize:geometry.pageSize,pagesPerBlock:geometry.pagesPerBlock,blockCount:geometry.blockCount,
            challenges:challenges,files:files.mapValues(BackupManifest.digest))
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        return (files,try e.encode(m))
    }
}
struct SNESActiveBoot2Failure:Error,Sendable {
    let binding:SNESRuntimeBinding,stage:String,reason:String,partial:Data
    func checkedExport()throws->(files:[String:Data],manifest:Data) {
        try binding.validate();let bytes=Data(partial.prefix(16384))
        struct Manifest:Encodable {
            let schemaVersion=1,scope="snes-active-boot2-diagnostic",complete=false
            let firmwareWritten=false,firmwareInstallEligible=false,firmwareRestoreEligible=false,bootEligible=false
            let binding:SNESRuntimeBinding,stage:String,reason:String,partialSHA256:String
        }
        let m=Manifest(binding:binding,stage:String(stage.prefix(128)),reason:String(reason.prefix(1024)),partialSHA256:BackupManifest.digest(bytes))
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        return (bytes.isEmpty ? [:]:["partial-frame.bin":bytes],try e.encode(m))
    }
}
private actor SNESActiveBoot2Connection:SNESActiveBoot2IO {
    let base:any SNESActiveBoot2IO,validate:@Sendable () throws->Void
    private var closed=false
    init(_ base:any SNESActiveBoot2IO,validate:@escaping @Sendable () throws->Void){self.base=base;self.validate=validate}
    private func checked<T:Sendable>(_ action:@Sendable () async throws->T) async throws->T {
        guard !closed else {throw LegacyInspectionError.disconnected};try validate();let value=try await action();try validate();return value
    }
    func inventory() async throws->[RecoveryProbeUSBDevice] {try await checked {try await self.base.inventory()}}
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {try await checked {try await self.base.boot(inputs,expected:expected)}}
    func connect(expected:RecoveryProbeUSBDevice) async throws {try await checked {try await self.base.connect(expected:expected)}}
    func observe() async throws->String {try await checked {try await self.base.observe()}}
    func readBoot2(_ slot:RecoveryBootSlot) async throws->RecoveryBoot2Read {try await checked {try await self.base.readBoot2(slot)}}
    func readBoot1() async throws->Data {try await checked {try await self.base.readBoot1()}}
    func readPartitions() async throws->Data {try await checked {try await self.base.readPartitions()}}
    func readDataSuperblock() async throws->Data {try await checked {try await self.base.readDataSuperblock()}}
    func geometry(challenge:UUID) async throws->Data {try await checked {try await self.base.geometry(challenge:challenge)}}
    func readActive(challenge:UUID) async throws->Data {try await checked {try await self.base.readActive(challenge:challenge)}}
    func disconnect() async {guard !closed else{return};closed=true;await base.disconnect()}
}
actor SNESActiveBoot2SnapshotService {
    private let session:RecoverySessionCoordinator
    private var busy=false,stage="checking-files",partial=Data()
    init(wait:@escaping @Sendable () async throws -> Void={try await Task.sleep(for:.seconds(1))}) {session=RecoverySessionCoordinator(wait:wait)}
    func capture(source:SNESPreparationSource,inputs:RecoveryBootInputs,helper:SNESBoundedReadHelper,io:any SNESActiveBoot2IO,progress:@escaping RecoveryProgressSink={_ in}) async throws -> SNESActiveBoot2Snapshot {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
        let validate:@Sendable ()throws->Void={try Task.checkCancellation();try source.revalidate();try helper.revalidate()}
        try validate();_=try SNESBoot2Bounds(partitions:source.partitions).checkedExtent(byteCount:source.stock.count)
        let connection=SNESActiveBoot2Connection(io,validate:validate)
        stage="starting-read-only-recovery";partial=Data()
        do {
            let (_,result)=try await session.run(inputs:inputs,io:connection,progress:progress,validateObservation:{
                let o=try SNESBackupPolicy.observation($0);try source.requireObservation(o);return o
            }) {context in
                try await self.read(source:source,helper:helper,context:context,connection:connection,progress:progress)
            }
            try validate();return result
        } catch {
            await connection.disconnect()
            if error is CancellationError || Task.isCancelled {throw CancellationError()}
            if let f=error as? SNESActiveBoot2ReadFailure,!f.partial.isEmpty {partial=f.partial}
            throw SNESActiveBoot2Failure(binding:source.source.runtimeBinding,stage:stage,reason:String(describing:error),partial:Data(partial.prefix(16384)))
        }
    }
    private func read(source:SNESPreparationSource,helper:SNESBoundedReadHelper,context:RecoverySessionContext,connection:SNESActiveBoot2Connection,progress:@escaping RecoveryProgressSink) async throws->SNESActiveBoot2Snapshot {
        stage="checking-original-startup";await progress(.readingCurrentKernel)
        for _ in 0..<2 {guard case .image(let bytes)=try await connection.readBoot2(.active),bytes==source.stock else {throw SNESRuntimeBinding.failure()}}
        stage="checking-bootloader";await progress(.readingBootloader)
        guard try await connection.readBoot1()==source.boot1 else {throw SNESRuntimeBinding.failure()}
        stage="checking-partitions";await progress(.checkingPartitions)
        guard try await connection.readPartitions()==source.partitions else {throw SNESRuntimeBinding.failure()}
        let header=try source.validateHeader(await connection.readDataSuperblock())
        let observation=try SNESBackupPolicy.observation(await connection.observe());try source.requireObservation(observation)
        guard observation.mounts==context.observation.mounts else {throw SNESRuntimeBinding.failure()}
        stage="reading-physical-layout"
        let a=UUID();partial=try await connection.geometry(challenge:a)
        let geometry=try SNESPhysicalGeometry(SNESPhysicalFrame(partial,kind:.geometry,challenge:a).bytes)
        stage="copying-startup-area";await progress(.readingCurrentKernel)
        let b=UUID();partial=try await connection.readActive(challenge:b)
        let active=try SNESPhysicalFrame(partial,kind:.active,challenge:b).bytes
        guard active.prefix(source.stock.count)==source.stock,try await connection.inventory()==[context.after] else {throw SNESRuntimeBinding.failure()}
        stage="verifying-startup-area";await progress(.verifying)
        let c=UUID();partial=try await connection.readActive(challenge:c)
        guard try SNESPhysicalFrame(partial,kind:.active,challenge:c).bytes==active else {throw SNESRuntimeBinding.failure()}
        let d=UUID();partial=try await connection.geometry(challenge:d)
        guard try SNESPhysicalGeometry(SNESPhysicalFrame(partial,kind:.geometry,challenge:d).bytes)==geometry else {throw SNESRuntimeBinding.failure()}
        stage="checking-final-state"
        guard try await connection.readPartitions()==source.partitions,try source.validateHeader(await connection.readDataSuperblock())==header else {throw SNESRuntimeBinding.failure()}
        let after=try SNESBackupPolicy.observation(await connection.observe());try source.requireObservation(after)
        guard after.mounts==context.observation.mounts,try await connection.inventory()==[context.after] else {throw SNESRuntimeBinding.failure()}
        return .init(source:source,helper:helper,context:context,geometry:geometry,header:header,active:active,challenges:[a,b,c,d])
    }
}
struct SNESActiveBoot2ReadFailure:Error,Sendable {let partial:Data,reason:String}
