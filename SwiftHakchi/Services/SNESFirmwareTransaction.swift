import Foundation
import SwiftHakchiCore

protocol SNESFirmwareIO:SNESActiveBoot2IO {
    func stage() async throws
    func verifyStaged() async throws
    func replace(_ permit:SNESFirmwareWritePermit) async throws
}
enum SNESFirmwareTransactionError:Error,LocalizedError {
    case uncertain,uncertainWithEvidence(String)
    var privateEvidence:String? {if case .uncertainWithEvidence(let value)=self {return value};return nil}
    var errorDescription:String? {"The console update could not be verified. Keep power and USB connected. Do not restart or try the update again; check the saved operation first."}
}
private actor SNESFirmwareConnection:SNESFirmwareIO {
    private let base:any SNESFirmwareIO,guardValue:SNESFirmwareGuard
    private var closed=false
    init(_ base:any SNESFirmwareIO,guardValue:SNESFirmwareGuard){self.base=base;self.guardValue=guardValue}
    private func checked<T:Sendable>(_ operation:@Sendable () async throws->T) async throws->T {
        guard !closed else {throw LegacyInspectionError.disconnected};try guardValue.validate()
        let value=try await operation()
        guard !closed else {throw LegacyInspectionError.disconnected};try guardValue.validate();return value
    }
    func inventory() async throws->[RecoveryProbeUSBDevice] {try await checked{try await self.base.inventory()}}
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {try await checked{try await self.base.boot(inputs,expected:expected)}}
    func connect(expected:RecoveryProbeUSBDevice) async throws {try await checked{try await self.base.connect(expected:expected)}}
    func observe() async throws->String {try await checked{try await self.base.observe()}}
    func readBoot2(_ slot:RecoveryBootSlot) async throws->RecoveryBoot2Read {try await checked{try await self.base.readBoot2(slot)}}
    func readBoot1() async throws->Data {try await checked{try await self.base.readBoot1()}}
    func readPartitions() async throws->Data {try await checked{try await self.base.readPartitions()}}
    func readDataSuperblock() async throws->Data {try await checked{try await self.base.readDataSuperblock()}}
    func geometry(challenge:UUID) async throws->Data {try await checked{try await self.base.geometry(challenge:challenge)}}
    func readActive(challenge:UUID) async throws->Data {try await checked{try await self.base.readActive(challenge:challenge)}}
    func stage() async throws {try await checked{try await self.base.stage()}}
    func verifyStaged() async throws {try await checked{try await self.base.verifyStaged()}}
    func replace(_ permit:SNESFirmwareWritePermit) async throws {try await checked{try await self.base.replace(permit)}}
    func disconnect() async {guard !closed else{return};closed=true;await base.disconnect()}
}
actor SNESFirmwareTransaction {
    enum Mode:Sendable {case preflight,write}
    private let session:RecoverySessionCoordinator
    private var busy=false,mayHaveIntent=false
    init(wait:@escaping @Sendable () async throws->Void={try await Task.sleep(for:.seconds(1))}) {session=RecoverySessionCoordinator(wait:wait)}
    func run(mode:Mode,journal:SNESFirmwareJournal,guard guardValue:SNESFirmwareGuard,inputs:RecoveryBootInputs,io:any SNESFirmwareIO,progress:@escaping RecoveryProgressSink={_ in}) async throws->RecoverySessionContext {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false};mayHaveIntent=false
        let connection=SNESFirmwareConnection(io,guardValue:guardValue);var eligible=false
        do {
            guard try await journal.phase()==(mode == .preflight ? .prepared:.preflightVerified) else {throw RestoreDirectory.failure()};eligible=true
            let material=try await journal.verifiedMaterial(guard:guardValue);try guardValue.require(material)
            let (context,_)=try await session.run(inputs:inputs,io:connection,progress:progress,validateObservation:{
                let observation=try SNESBackupPolicy.observation($0);try material.source.requireObservation(observation);return observation
            }) {context in
                try await self.perform(mode:mode,material:material,journal:journal,guardValue:guardValue,connection:connection,context:context,progress:progress)
            }
            try guardValue.validate()
            if mode == .preflight {try await journal.preflightVerified()} else {try await journal.readbackVerified()}
            return context
        } catch {
            await connection.disconnect()
            if mayHaveIntent {
                _=await Task.detached {try? await journal.uncertain()}.value
                let cause=(error as? SNESFirmwareCommandFailure)?.diagnostic ?? String(describing:error)
                throw SNESFirmwareTransactionError.uncertainWithEvidence(String(decoding:Data(cause.utf8).prefix(12000),as:UTF8.self))
            }
            if eligible {_=await Task.detached {try? await journal.stoppedBeforeWrite()}.value}
            throw error
        }
    }
    private func perform(mode:Mode,material m:SNESFirmwareMaterial,journal:SNESFirmwareJournal,guardValue:SNESFirmwareGuard,connection:any SNESFirmwareIO,context:RecoverySessionContext,progress:@escaping RecoveryProgressSink) async throws {
        let currentImage=m.currentImage
        let targetImage=m.targetImage
        await progress(.readingCurrentKernel);try guardValue.validate()
        for _ in 0..<2 {guard case .image(let bytes)=try await connection.readBoot2(.active),bytes==currentImage else {throw SNESRuntimeBinding.failure()}}
        await progress(.readingBootloader);try guardValue.validate()
        guard try await connection.readBoot1()==m.source.boot1 else {throw SNESRuntimeBinding.failure()}
        await progress(.checkingPartitions);try guardValue.validate()
        guard try await connection.readPartitions()==m.source.partitions else {throw SNESRuntimeBinding.failure()}
        let header=try m.source.validateHeader(await connection.readDataSuperblock())
        try await checkState(m,context:context,connection:connection)
        try await checkGeometry(m,connection:connection)
        for _ in 0..<2 {try await comparePhysical(m.preimage,connection:connection)}
        try await checkState(m,context:context,connection:connection)
        await progress(.stagingStartup);try guardValue.validate()
        try await connection.stage();try await connection.verifyStaged()
        try await checkState(m,context:context,connection:connection)
        try await checkGeometry(m,connection:connection)
        guard try m.source.validateHeader(await connection.readDataSuperblock())==header else {throw SNESRuntimeBinding.failure()}
        _=try await journal.verifiedMaterial(guard:guardValue)
        guard mode == .write else {return}
        // From this point even lost acknowledgement or cancellation is uncertain.
        mayHaveIntent=true
        let permit=try await journal.beginWrite();try guardValue.validate()
        await progress(m.direction == .install ? .writingStartup:.restoringStartup);try guardValue.validate()
        try await connection.replace(permit)
        await progress(.readingBack);try guardValue.validate()
        for _ in 0..<2 {try await comparePhysical(m.target,connection:connection)}
        try await checkGeometry(m,connection:connection)
        guard case .image(let after)=try await connection.readBoot2(.active),after==targetImage,
              try await connection.readBoot1()==m.source.boot1,try await connection.readPartitions()==m.source.partitions,
              try m.source.validateHeader(await connection.readDataSuperblock())==header else {throw SNESRuntimeBinding.failure()}
        try await checkState(m,context:context,connection:connection)
        try guardValue.validate();await progress(.verifying);try guardValue.validate()
    }
    private func comparePhysical(_ expected:Data,connection:any SNESActiveBoot2IO) async throws {
        let challenge=UUID(),raw=try await connection.readActive(challenge:challenge)
        guard try SNESPhysicalFrame(raw,kind:.active,challenge:challenge).bytes==expected else {throw SNESRuntimeBinding.failure()}
    }
    private func checkGeometry(_ m:SNESFirmwareMaterial,connection:any SNESActiveBoot2IO) async throws {
        let challenge=UUID(),raw=try await connection.geometry(challenge:challenge)
        guard try SNESPhysicalFrame(raw,kind:.geometry,challenge:challenge).bytes==m.geometry else {throw SNESRuntimeBinding.failure()}
    }
    private func checkState(_ m:SNESFirmwareMaterial,context:RecoverySessionContext,connection:any RecoveryProbeIO) async throws {
        let observation=try SNESBackupPolicy.observation(await connection.observe());try m.source.requireObservation(observation)
        guard observation.mounts==context.observation.mounts,try await connection.inventory()==[context.after] else {throw SNESRuntimeBinding.failure()}
    }
}
