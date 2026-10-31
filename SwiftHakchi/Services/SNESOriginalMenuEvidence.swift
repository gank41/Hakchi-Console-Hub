import Foundation
import SwiftHakchiCore

struct SNESOriginalMenuCheckpoint: Sendable {
    let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, challenge: UUID, report: Data
    private struct Manifest: Codable {
        let schemaVersion: Int, complete: Bool, firmwareWritten: Bool, firmwareRestoreEligible: Bool
        let scope: String, imageSHA256: String, nonce: String, binding: SNESRuntimeBinding, reportSHA256: String
        let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, challenge: UUID
    }
    func checkedExport(menu:PreparedSNESOriginalMenu) throws -> (files:[String:Data],manifest:Data) {
        try menu.validateCurrent()
        guard try SNESOriginalMenuUSBPolicy.after([after],original:before)==after else { throw SNESRuntimeBinding.failure() }
        _=try SNESOriginalMenuReport(report,expected:menu.expectation,challenge:challenge,state:.preMenu)
        let m=Manifest(schemaVersion:1,complete:true,firmwareWritten:false,firmwareRestoreEligible:false,
            scope:"snes-original-menu-preflight",imageSHA256:BackupManifest.digest(menu.image),nonce:menu.nonce,binding:menu.material.binding,reportSHA256:BackupManifest.digest(report),before:before,after:after,challenge:challenge)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return (["checkpoint.bin":report],try encoder.encode(m))
    }
    static func load(directory url:URL,menu:PreparedSNESOriginalMenu) throws -> Self {
        let dir=try RestoreDirectory(url),prefix="SNES-Original-Menu-Checkpoint-"
        guard dir.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESRuntimeBinding.failure() }
        let raw=try dir.read("manifest.json",maximum:65536),m=try JSONDecoder().decode(Manifest.self,from:raw)
        let result=Self(before:m.before,after:m.after,challenge:m.challenge,report:try dir.read("checkpoint.bin",maximum:65536))
        let checked=try result.checkedExport(menu:menu)
        guard let actual=try JSONSerialization.jsonObject(with:checked.manifest) as? NSDictionary,
              let saved=try JSONSerialization.jsonObject(with:raw) as? [String:Any],actual.isEqual(to:saved) else { throw SNESRuntimeBinding.failure() }
        try dir.check();return result
    }
    /// Only a freshly committed and reconstructed Mac receipt yields the transient launch request.
    func persistForLaunch(menu:PreparedSNESOriginalMenu,store:RecoveryBootSnapshotStore) async throws -> SNESOriginalMenuLaunchRequest {
        try menu.validateCurrent()
        let directory=try await store.saveSNESOriginalMenuCheckpoint(self,menu:menu)
        try menu.validateCurrent()
        let loaded=try Self.load(directory:directory,menu:menu)
        guard loaded.before==before,loaded.after==after,loaded.challenge==challenge,loaded.report==report else { throw SNESRuntimeBinding.failure() }
        let manifest=try RestoreDirectory(directory).read("manifest.json",maximum:65536)
        return SNESOriginalMenuLaunchRequest(menu:menu,checkpoint:self,directory:directory,manifestSHA256:BackupManifest.digest(manifest))
    }
}
struct SNESOriginalMenuLaunchRequest: Sendable {
    private let menu: PreparedSNESOriginalMenu, checkpoint: SNESOriginalMenuCheckpoint, manifestSHA256: String
    let checkpointDirectory: URL
    fileprivate init(menu:PreparedSNESOriginalMenu,checkpoint:SNESOriginalMenuCheckpoint,directory:URL,manifestSHA256:String) {
        self.menu=menu;self.checkpoint=checkpoint;checkpointDirectory=directory;self.manifestSHA256=manifestSHA256
    }
    func validateCurrent() throws {
        try menu.validateCurrent()
        let loaded=try SNESOriginalMenuCheckpoint.load(directory:checkpointDirectory,menu:menu)
        guard loaded.report==checkpoint.report,loaded.challenge==checkpoint.challenge,loaded.before==checkpoint.before,loaded.after==checkpoint.after,
              try BackupManifest.digest(RestoreDirectory(checkpointDirectory).read("manifest.json",maximum:65536))==manifestSHA256 else { throw SNESRuntimeBinding.failure() }
    }
    var command:String { "exec /probe/busybox sh /probe/launch " + menu.nonce + " " + checkpoint.challenge.uuidString + " " + BackupManifest.digest(checkpoint.report) }
    var acknowledgement:Data { Data("SWIFTHAKCHI_SNES_ORIGINAL_LAUNCH_V1\nNONCE=\(menu.nonce)\nCHECKPOINT_SHA=\(BackupManifest.digest(checkpoint.report))\nEND\n".utf8) }
}
struct SNESOriginalMenuResult: Sendable {
    let checkpoint: SNESOriginalMenuCheckpoint, checkpointDirectory: URL
    let challenges:[UUID],reports:[Data],diagnostics:Data,phase:String
    private struct Manifest: Codable {
        let schemaVersion:Int,complete:Bool,firmwareWritten:Bool,firmwareRestoreEligible:Bool,userGameplayConfirmed:Bool,stockReturnConfirmed:Bool
        let scope:String,phase:String,imageSHA256:String,nonce:String,checkpointPath:String,checkpointSHA256:String
        let challenges:[UUID],reportSHA256:[String],diagnosticSHA256:String
    }
    func checkedExport(menu:PreparedSNESOriginalMenu) throws -> (files:[String:Data],manifest:Data) {
        try menu.validateCurrent()
        let saved=try SNESOriginalMenuCheckpoint.load(directory:checkpointDirectory,menu:menu)
        guard saved.report==checkpoint.report,saved.challenge==checkpoint.challenge,saved.before==checkpoint.before,saved.after==checkpoint.after,
              ["started","after-gameplay"].contains(phase),challenges.count==2,reports.count==2,Set(challenges).count==2,!challenges.contains(checkpoint.challenge) else { throw SNESRuntimeBinding.failure() }
        let baseline=try SNESOriginalMenuReport(checkpoint.report,expected:menu.expectation,challenge:checkpoint.challenge,state:.preMenu).baseline
        for (challenge,raw) in zip(challenges,reports) {
            guard try SNESOriginalMenuReport(raw,expected:menu.expectation,challenge:challenge,state:.ready).baseline==baseline else { throw SNESRuntimeBinding.failure() }
        }
        _=try SNESOriginalMenuDiagnostics(diagnostics,nonce:menu.nonce)
        let checkpointManifest=try RestoreDirectory(checkpointDirectory).read("manifest.json",maximum:65536)
        let m=Manifest(schemaVersion:1,complete:true,firmwareWritten:false,firmwareRestoreEligible:false,userGameplayConfirmed:false,stockReturnConfirmed:false,
            scope:"snes-original-menu-machine-result",phase:phase,imageSHA256:BackupManifest.digest(menu.image),nonce:menu.nonce,
            checkpointPath:checkpointDirectory.path,checkpointSHA256:BackupManifest.digest(checkpointManifest),challenges:challenges,reportSHA256:reports.map(BackupManifest.digest),diagnosticSHA256:BackupManifest.digest(diagnostics))
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return (["report-0.bin":reports[0],"report-1.bin":reports[1],"diagnostic.log":diagnostics],try encoder.encode(m))
    }
    static func loadStarted(directory url:URL,menu:PreparedSNESOriginalMenu) throws -> Self {
        let dir=try RestoreDirectory(url),prefix="SNES-Original-Menu-Result-"
        guard dir.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESRuntimeBinding.failure() }
        let raw=try dir.read("manifest.json",maximum:65536),m=try JSONDecoder().decode(Manifest.self,from:raw)
        guard m.phase=="started",m.checkpointPath.hasPrefix("/"),!m.checkpointPath.contains("\0"),m.checkpointPath.utf8.count<=4096 else { throw SNESRuntimeBinding.failure() }
        let checkpointURL=URL(fileURLWithPath:m.checkpointPath)
        let checkpoint=try SNESOriginalMenuCheckpoint.load(directory:checkpointURL,menu:menu)
        let result=Self(checkpoint:checkpoint,checkpointDirectory:checkpointURL,challenges:m.challenges,
            reports:try (0..<2).map { try dir.read("report-\($0).bin",maximum:65536) },diagnostics:try dir.read("diagnostic.log",maximum:65536),phase:m.phase)
        let checked=try result.checkedExport(menu:menu)
        guard let actual=try JSONSerialization.jsonObject(with:checked.manifest) as? NSDictionary,
              let saved=try JSONSerialization.jsonObject(with:raw) as? [String:Any],actual.isEqual(to:saved) else { throw SNESRuntimeBinding.failure() }
        try dir.check();return result
    }
}
struct SNESOriginalMenuFailure: Error, LocalizedError, Sendable {
    let stage:String,report:Data,diagnostics:Data,checkpoint:SNESOriginalMenuCheckpoint?
    let capturedReports:[Data]
    init(stage:String,report:Data,diagnostics:Data,checkpoint:SNESOriginalMenuCheckpoint?,capturedReports:[Data]=[]) {
        self.stage=stage;self.report=Data(report.prefix(65536));self.diagnostics=Data(diagnostics.prefix(65536));self.checkpoint=checkpoint
        self.capturedReports=capturedReports.prefix(2).map {Data($0.prefix(65536))}
    }
    var errorDescription:String? { "The temporary SNES test stopped. Private details were saved on this Mac. No firmware was installed." }
    func checkedExport(menu:PreparedSNESOriginalMenu) throws -> (files:[String:Data],manifest:Data) {
        try menu.material.binding.validate()
        guard stage.utf8.count<=64,stage.utf8.allSatisfy({(97...122).contains($0) || $0==45}) else { throw SNESRuntimeBinding.failure() }
        let report=Data(report.prefix(65536)),diagnostics=Data(diagnostics.prefix(65536))
        var files=["partial-report.bin":Data("SWIFTHAKCHI_ORIGINAL_MENU_PARTIAL_V1 \(report.count) \(BackupManifest.digest(report))\n".utf8)+report,
                   "diagnostic.log":Data("SWIFTHAKCHI_ORIGINAL_MENU_LOG_V1 \(diagnostics.count) \(BackupManifest.digest(diagnostics))\n".utf8)+diagnostics]
        for (index,raw) in capturedReports.enumerated() where !raw.isEmpty {files["report-\(index).bin"]=raw}
        if let checkpoint { files["captured-checkpoint.bin"]=Data(checkpoint.report.prefix(65536)) }
        let json:[String:Any]=["schemaVersion":1,"complete":false,"firmwareWritten":false,"firmwareRestoreEligible":false,
            "scope":"snes-original-menu-diagnostic","stage":stage,"imageSHA256":BackupManifest.digest(menu.image),
            "reportSHA256":BackupManifest.digest(report),"diagnosticSHA256":BackupManifest.digest(diagnostics),"checkpointCaptured":checkpoint != nil,"capturedReportSHA256":capturedReports.map(BackupManifest.digest)]
        return (files,try JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys]))
    }
}
