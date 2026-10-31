import Foundation
import SwiftHakchiCore

/// Reopened inert stock evidence, bound to the accepted installation and its own captured console.
struct SNESOriginalGamesPackage:Sendable {
    let frame:SNESOriginalGamesFrame,directoryURL:URL,manifestSHA256:String
    private let sourceSeal:SNESFirmwareSourceSeal,guardValue:SNESFirmwareGuard
    private struct Manifest:Codable {
        let schemaVersion:Int,complete:Bool,firmwareWritten:Bool,syncEligible:Bool,console:String
        let operation:UUID,reviewSHA256:String,binding:SNESRuntimeBinding,imageSHA256:String,targetSHA256:String
        let device:RecoveryProbeUSBDevice,catalogChallenge:UUID,challenges:[UUID],gameCount:Int,fileSHA256:[String:String]
    }
    static func load(directory:URL,accepted:SNESFirmwareAcceptedInstall)throws->Self {
        try Task.checkCancellation()
        let material=accepted.material,checked=try SNESFirmwareGuard.prepare(material),d=try RestoreDirectory(directory),prefix="SNES-Original-Games-"
        let seal=try SNESFirmwareSourceSeal.capture(directories:[d.url],files:[])
        guard d.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(d.url.lastPathComponent.dropFirst(prefix.count))) != nil,
              Set(try d.names())==Set(["manifest.json","catalog.frame","report-0.txt","report-1.txt"]) else {throw SNESOriginalGamesFrame.failure()}
        let raw=try d.read("manifest.json",maximum:65536),m=try JSONDecoder().decode(Manifest.self,from:raw)
        let encoder=JSONEncoder()
        guard let canonical=try JSONSerialization.jsonObject(with:encoder.encode(m)) as? NSDictionary,
              let original=try JSONSerialization.jsonObject(with:raw) as? [String:Any],canonical.isEqual(to:original),
              m.schemaVersion==1,m.complete,!m.firmwareWritten,!m.syncEligible,m.console=="snes-usa",material.direction == .install,
              m.operation==material.id,m.reviewSHA256==accepted.reviewSHA256,m.reviewSHA256==checked.reviewSHA256,
              m.binding==material.trial.candidate.material.binding,m.imageSHA256==BackupManifest.digest(material.trial.image),
              m.targetSHA256==BackupManifest.digest(material.target),m.challenges.count==2,Set(m.challenges+[m.catalogChallenge]).count==3,
              Set(m.fileSHA256.keys)==Set(["catalog.frame","report-0.txt","report-1.txt"]) else {throw SNESOriginalGamesFrame.failure()}
        _=try SNESStartupTrialUSBPolicy.nativeIdentity(m.device)
        let expected=try SNESStartupTrialExpectation.checked(material.trial)
        guard m.device.deviceVersion==expected.deviceVersion else {throw SNESOriginalGamesFrame.failure()}
        func read(_ name:String,_ maximum:Int)throws->Data {
            let bytes=try d.read(name,maximum:maximum)
            guard BackupManifest.digest(bytes)==m.fileSHA256[name] else {throw SNESOriginalGamesFrame.failure()};return bytes
        }
        let first=try SNESStartupTrialReport(read("report-0.txt",16384),expected:expected,challenge:m.challenges[0])
        let last=try SNESStartupTrialReport(read("report-1.txt",16384),expected:expected,challenge:m.challenges[1])
        let frame=try SNESOriginalGamesFrame(read("catalog.frame",SNESOriginalGamesFrame.maximumSize),binding:m.binding,challenge:m.catalogChallenge)
        guard first.mcpPID==last.mcpPID,first.daemonPID==last.daemonPID,frame.entries.count==m.gameCount,
              let launcher=material.trial.candidate.material.support.frame.records.first(where:{$0.path=="usr/bin/clover-canoe-shvc"}),
              launcher.digest==BackupManifest.digest(frame.launcher) else {throw SNESOriginalGamesFrame.failure()}
        try seal.validate();try checked.require(material);try d.check()
        return .init(frame:frame,directoryURL:d.url,manifestSHA256:BackupManifest.digest(raw),sourceSeal:seal,guardValue:checked)
    }
    func revalidate()throws {try Task.checkCancellation();try sourceSeal.validate();try guardValue.validate()}
}
