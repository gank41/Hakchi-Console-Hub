import Foundation
import SwiftHakchiCore

/// Completed RAM startup and post-gameplay reports, without write authority.
struct SNESFirmwareTrialProof:Sendable {
    let started:URL,played:URL,startedSHA256:String,playedSHA256:String
    private init(started:URL,played:URL,startedSHA256:String,playedSHA256:String) {
        self.started=started;self.played=played;self.startedSHA256=startedSHA256;self.playedSHA256=playedSHA256
    }
    private struct Record:Codable {
        let schemaVersion:Int,scope:String,complete:Bool,phase:String
        let firmwareWritten:Bool,firmwareInstallEligible:Bool,firmwareRestoreEligible:Bool,userGameplayConfirmed:Bool,profileWritesPossible:Bool
        let binding:SNESRuntimeBinding,imageSHA256:String,preflightSHA256:String
        let before:RecoveryProbeUSBDevice,after:RecoveryProbeUSBDevice,challenges:[UUID],reportSHA256:[String]
    }
    static func load(started:URL,played:URL,trial:PreparedSNESStartupTrial)throws->Self {
        try trial.validateCurrent()
        let first=try SNESStartupTrialResult.loadStarted(directory:started,trial:trial)
        let a=try RestoreDirectory(started),b=try RestoreDirectory(played),prefix="SNES-Startup-Trial-Result-"
        guard a.url != b.url,b.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(b.url.lastPathComponent.dropFirst(prefix.count))) != nil,
              Set(try b.names())==Set(["manifest.json","report-0.txt","report-1.txt"]) else {throw SNESRuntimeBinding.failure()}
        let firstRaw=try a.read("manifest.json",maximum:65536),raw=try b.read("manifest.json",maximum:65536),m=try JSONDecoder().decode(Record.self,from:raw)
        guard let canonical=try JSONSerialization.jsonObject(with:JSONEncoder().encode(m)) as? NSDictionary,
              let original=try JSONSerialization.jsonObject(with:raw) as? [String:Any],canonical.isEqual(to:original),
              m.schemaVersion==1,m.scope=="snes-original-profile-startup-trial",m.complete,m.phase=="after-gameplay",
              !m.firmwareWritten,!m.firmwareInstallEligible,!m.firmwareRestoreEligible,!m.userGameplayConfirmed,m.profileWritesPossible,
              m.binding==trial.candidate.material.binding,m.imageSHA256==BackupManifest.digest(trial.image),m.preflightSHA256==trial.evidence.manifestSHA256,
              m.before==first.before,m.after==first.after,m.challenges.count==2,Set(m.challenges).count==2,
              Set(m.challenges).isDisjoint(with:first.challenges),m.reportSHA256.count==2 else {throw SNESRuntimeBinding.failure()}
        let expected=try SNESStartupTrialExpectation.checked(trial)
        for i in 0..<2 {
            let bytes=try b.read("report-\(i).txt",maximum:16384)
            guard BackupManifest.digest(bytes)==m.reportSHA256[i] else {throw SNESRuntimeBinding.failure()}
            _=try SNESStartupTrialReport(bytes,expected:expected,challenge:m.challenges[i])
        }
        try a.check();try b.check();try trial.validateCurrent()
        return .init(started:a.url,played:b.url,startedSHA256:BackupManifest.digest(firstRaw),playedSHA256:BackupManifest.digest(raw))
    }
    func revalidate(trial:PreparedSNESStartupTrial)throws {
        let current=try Self.load(started:started,played:played,trial:trial)
        guard current.startedSHA256==startedSHA256,current.playedSHA256==playedSHA256 else {throw SNESRuntimeBinding.failure()}
    }
}
