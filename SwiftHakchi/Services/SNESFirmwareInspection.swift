import Foundation
import SwiftHakchiCore

struct SNESFirmwareInspectionResult:Sendable {
    enum Classification:String,Sendable {case preimage,target,mixed}
    let classification:Classification,observedSHA256:String,challenges:[UUID]
    let context:RecoverySessionContext
    fileprivate init(classification:Classification,observedSHA256:String,challenges:[UUID],context:RecoverySessionContext) {
        self.classification=classification;self.observedSHA256=observedSHA256;self.challenges=challenges;self.context=context
    }
}
/// Deliberately read-only: no firmware staging, writer or retry API.
private actor SNESFirmwareInspectionConnection:SNESActiveBoot2IO {
    private let base:any SNESActiveBoot2IO,guardValue:SNESFirmwareGuard
    private var closed=false
    init(_ base:any SNESActiveBoot2IO,guardValue:SNESFirmwareGuard){self.base=base;self.guardValue=guardValue}
    private func checked<T:Sendable>(_ action:@Sendable () async throws->T) async throws->T {
        guard !closed else {throw LegacyInspectionError.disconnected};try guardValue.validate()
        let value=try await action()
        guard !closed else {throw LegacyInspectionError.disconnected};try guardValue.validate();return value
    }
    func inventory() async throws->[RecoveryProbeUSBDevice]{try await checked{try await self.base.inventory()}}
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws{try await checked{try await self.base.boot(inputs,expected:expected)}}
    func connect(expected:RecoveryProbeUSBDevice) async throws{try await checked{try await self.base.connect(expected:expected)}}
    func observe() async throws->String{try await checked{try await self.base.observe()}}
    func readBoot2(_ slot:RecoveryBootSlot) async throws->RecoveryBoot2Read{try await checked{try await self.base.readBoot2(slot)}}
    func readBoot1() async throws->Data{try await checked{try await self.base.readBoot1()}}
    func readPartitions() async throws->Data{try await checked{try await self.base.readPartitions()}}
    func readDataSuperblock() async throws->Data{try await checked{try await self.base.readDataSuperblock()}}
    func geometry(challenge:UUID) async throws->Data{try await checked{try await self.base.geometry(challenge:challenge)}}
    func readActive(challenge:UUID) async throws->Data{try await checked{try await self.base.readActive(challenge:challenge)}}
    func disconnect() async{guard !closed else{return};closed=true;await base.disconnect()}
}
actor SNESFirmwareInspection {
    private let session:RecoverySessionCoordinator
    private var busy=false
    init(wait:@escaping @Sendable () async throws->Void={try await Task.sleep(for:.seconds(1))}) {session=RecoverySessionCoordinator(wait:wait)}
    func run(journal:SNESFirmwareJournal,guard checked:SNESFirmwareGuard,inputs:RecoveryBootInputs,io:any SNESActiveBoot2IO,progress:@escaping RecoveryProgressSink={_ in}) async throws->SNESFirmwareInspectionResult {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
        let connection=SNESFirmwareInspectionConnection(io,guardValue:checked)
        do {
            let phase=try await journal.phase()
            guard [.writeIntent,.uncertain,.readbackVerified].contains(phase) else {throw RestoreDirectory.failure()}
            let m=try await journal.verifiedMaterial(guard:checked);try checked.require(m)
            let (_,result)=try await session.run(inputs:inputs,io:connection,progress:progress,validateObservation:{raw in
                let observation=try SNESBackupPolicy.observation(raw);try m.source.requireObservation(observation);return observation
            }) {context in
                guard try await connection.readBoot1()==m.source.boot1,try await connection.readPartitions()==m.source.partitions else {throw SNESRuntimeBinding.failure()}
                let header=try m.source.validateHeader(await connection.readDataSuperblock())
                var ids:[UUID]=[]
                let geometryID=UUID();ids.append(geometryID)
                guard try SNESPhysicalFrame(await connection.geometry(challenge:geometryID),kind:.geometry,challenge:geometryID).bytes==m.geometry else {throw SNESRuntimeBinding.failure()}
                let firstID=UUID();ids.append(firstID)
                let bytes=try SNESPhysicalFrame(await connection.readActive(challenge:firstID),kind:.active,challenge:firstID).bytes
                let secondID=UUID();ids.append(secondID)
                guard try SNESPhysicalFrame(await connection.readActive(challenge:secondID),kind:.active,challenge:secondID).bytes==bytes else {throw SNESRuntimeBinding.failure()}
                let lastID=UUID();ids.append(lastID)
                guard try SNESPhysicalFrame(await connection.geometry(challenge:lastID),kind:.geometry,challenge:lastID).bytes==m.geometry,
                      try await connection.readPartitions()==m.source.partitions,try m.source.validateHeader(await connection.readDataSuperblock())==header,
                      try await connection.readBoot1()==m.source.boot1 else {throw SNESRuntimeBinding.failure()}
                let after=try SNESBackupPolicy.observation(await connection.observe());try m.source.requireObservation(after)
                guard after.mounts==context.observation.mounts,try await connection.inventory()==[context.after] else {throw SNESRuntimeBinding.failure()}
                let classification:SNESFirmwareInspectionResult.Classification=bytes==m.preimage ? .preimage:bytes==m.target ? .target:.mixed
                return SNESFirmwareInspectionResult(classification:classification,observedSHA256:BackupManifest.digest(bytes),challenges:ids,context:context)
            }
            try checked.validate()
            guard try await journal.phase()==phase else {throw RestoreDirectory.failure()}
            return result
        } catch {await connection.disconnect();throw error}
    }
}
