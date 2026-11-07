import Foundation
import SwiftHakchiCore

/// Inert evidence only; no firmware or boot authority is encoded in its manifest.
struct SNESStartupPreflightEvidence:Sendable {
    let directory:URL,manifestSHA256:String
    let backupMatches:Bool
    let parent:SNESMenuStartupParent?
    private struct Record:Decodable {
        let schemaVersion:Int,scope:String,complete:Bool
        let parent:SNESMenuStartupParent.Record?
        let firmwareWritten:Bool,firmwareInstallEligible:Bool,bootEligible:Bool,firmwareRestoreEligible:Bool
        let operationID:UUID,binding:SNESRuntimeBinding,context:SNESDataSnapshotResult.RecoverySessionContextRecord
        let imageSHA256:String,stockSHA256:String,dataSHA256:String,headerSHA256:String,initialBackupDataSHA256:String
        let backupMatchesCheckedData:Bool
        let imageBytes:Int,stockBytes:Int,dataBytes:Int,currentDataBackup:String
    }
    static func load(directory:URL,candidate:SNESStartupAdapterCandidate,parent:SNESMenuStartupParent?=nil) throws -> Self {
        guard parent != nil || !candidate.hasMenuSupport else {throw SNESRuntimeBinding.failure()}
        try Task.checkCancellation();try candidate.material.revalidate();try candidate.backup.revalidate()
        let dir=try RestoreDirectory(directory),prefix="SNES-Startup-Preflight-"
        guard dir.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil,
              Set(try dir.names())==Set(["manifest.json","data-header.bin"]) else {throw SNESRuntimeBinding.failure()}
        let raw=try dir.read("manifest.json",maximum:65536),m=try JSONDecoder().decode(Record.self,from:raw)
        let source=try SNESPreparationSource.load(candidate.material.support.setup)
        if let parent {
            try parent.require(candidate)
            guard m.schemaVersion==2,m.scope=="snes-menu-startup-no-flash-preflight",m.parent==parent.record else {throw SNESRuntimeBinding.failure()}
        } else {
            guard m.schemaVersion==1,m.scope=="snes-startup-no-flash-preflight",m.parent==nil else {throw SNESRuntimeBinding.failure()}
        }
        guard m.complete,
              !m.firmwareWritten,!m.firmwareInstallEligible,!m.bootEligible,!m.firmwareRestoreEligible,
              m.binding==candidate.material.binding,m.imageBytes==candidate.image.count,m.imageSHA256==BackupManifest.digest(candidate.image),
              m.stockBytes==source.stock.count,m.stockSHA256==BackupManifest.digest(source.stock),m.dataBytes==candidate.backup.byteCount,
              m.initialBackupDataSHA256==candidate.backup.sha256,m.currentDataBackup==candidate.backup.directory.lastPathComponent,
              SNESDataSnapshotChunk.isDigest(m.dataSHA256) else {throw SNESRuntimeBinding.failure()}
        _=try RecoveryProbePolicy.before([m.context.before])
        guard try RecoveryProbePolicy.after([m.context.after],original:m.context.before)==m.context.after else {throw SNESRuntimeBinding.failure()}
        try source.requireObservation(m.context.observation)
        let header=try dir.read("data-header.bin",maximum:2048),old=try RestoreDirectory(candidate.backup.directory).read("data-header.bin",maximum:2048)
        guard header.count==2048,BackupManifest.digest(header)==m.headerSHA256,
              m.backupMatchesCheckedData==(header==old && m.dataSHA256==candidate.backup.sha256) else {throw SNESRuntimeBinding.failure()}
        _=try source.validateHeader(Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(m.headerSHA256)\n".utf8)+header)
        try dir.check();try parent?.validate();return .init(directory:dir.url,manifestSHA256:BackupManifest.digest(raw),backupMatches:m.backupMatchesCheckedData,parent:parent)
    }
    func revalidate(candidate:SNESStartupAdapterCandidate) throws {
        let current=try Self.load(directory:directory,candidate:candidate,parent:parent)
        guard current.manifestSHA256==manifestSHA256,current.backupMatches==backupMatches else {throw SNESRuntimeBinding.failure()}
    }
    func requireReceipt(_ receipt: SNESStartupPreflightReceipt, candidate: SNESStartupAdapterCandidate) throws {
        guard receipt.record.kind == .preflight, receipt.record.directory == directory,
              receipt.record.manifestSHA256 == manifestSHA256, receipt.backupMatches == backupMatches else { throw SNESRuntimeBinding.failure() }
        try revalidate(candidate: candidate)
    }
}
/// Dedicated reviewed RAM-startup capability; no firmware writer accepts this type.
struct PreparedSNESStartupTrial:Sendable {
    let candidate:SNESStartupAdapterCandidate,evidence:SNESStartupPreflightEvidence,fes1:Data,uboot:Data
    private let imageSHA256:String,ubootSHA256:String
    var image:Data {candidate.image}
    var expectedHWID:String {candidate.material.binding.expectedHWID}
    private init(candidate:SNESStartupAdapterCandidate,evidence:SNESStartupPreflightEvidence,recovery:PreparedRecoveryBoot) {
        self.candidate=candidate;self.evidence=evidence;fes1=recovery.fes1;uboot=recovery.uboot
        imageSHA256=BackupManifest.digest(candidate.image);ubootSHA256=BackupManifest.digest(recovery.uboot)
    }
    static func prepare(candidate:SNESStartupAdapterCandidate,evidence:URL,recovery:RecoveryBootInputs,parent:SNESMenuStartupParent?=nil) throws -> Self {
        _=try candidate.checkedExport()
        let receipt=try SNESStartupPreflightEvidence.load(directory:evidence,candidate:candidate,parent:parent)
        let trial=Self(candidate:candidate,evidence:receipt,recovery:try recovery.prepare())
        try trial.validateCurrent();return trial
    }
    /// App handoff: do not use an older data backup to start a first-install trial.
    static func prepare(candidate: SNESStartupAdapterCandidate, receipt: SNESStartupPreflightReceipt,
                        recovery: RecoveryBootInputs, parent: SNESMenuStartupParent? = nil) throws -> Self {
        guard receipt.backupMatches else { throw SNESRuntimeBinding.failure() }
        let evidence = try SNESStartupPreflightEvidence.load(directory: receipt.record.directory, candidate: candidate, parent: parent)
        try evidence.requireReceipt(receipt, candidate: candidate)
        let trial = try prepare(candidate: candidate, evidence: receipt.record.directory, recovery: recovery, parent: parent)
        try trial.evidence.requireReceipt(receipt, candidate: candidate)
        return trial
    }
    func validateCurrent() throws {
        try Task.checkCancellation();try evidence.revalidate(candidate:candidate)
        guard BackupManifest.digest(image)==imageSHA256,BackupManifest.digest(uboot)==ubootSHA256,
              BackupManifest.digest(fes1)==RecoveryPayloadValidator.fes1SHA256 else {throw SNESRuntimeBinding.failure()}
    }
}
enum SNESStartupSID {
    static let address:UInt32=0x01c23800
    static func decode(_ bytes:Data) throws -> String {
        guard bytes.count==16,bytes.contains(where:{$0 != 0}) else {throw SNESRuntimeBinding.failure()}
        return stride(from:0,to:16,by:4).map { offset in
            let word=(0..<4).reduce(UInt32(0)) {$0 | UInt32(bytes[offset+$1]) << ($1*8)}
            return String(format:"%08x",word)
        }.joined()
    }
}
