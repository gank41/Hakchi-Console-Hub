import Foundation
import SwiftHakchiCore

protocol SNESOriginalGamesIO: SNESInstalledStartupIO {
    func originalGames(challenge: UUID) async throws -> Data
}

/// Read-only evidence. This type cannot issue a game upload, menu switch or firmware write.
struct SNESOriginalGamesResult: Sendable {
    let device: RecoveryProbeUSBDevice
    let catalogChallenge: UUID
    let catalog: Data
    let challenges: [UUID], reports: [Data]
    private let accepted: SNESFirmwareAcceptedInstall
    private let checked: SNESFirmwareGuard
    fileprivate init(device:RecoveryProbeUSBDevice,catalogChallenge:UUID,catalog:Data,challenges:[UUID],reports:[Data],accepted:SNESFirmwareAcceptedInstall,checked:SNESFirmwareGuard) {
        self.device=device;self.catalogChallenge=catalogChallenge;self.catalog=catalog
        self.challenges=challenges;self.reports=reports;self.accepted=accepted;self.checked=checked
    }
    func checkedExport() throws -> (files:[String:Data],manifest:Data) {
        let material=accepted.material
        try checked.require(material)
        guard accepted.reviewSHA256==checked.reviewSHA256,material.direction == .install,
              challenges.count==2,reports.count==2,Set(challenges+[catalogChallenge]).count==3 else {throw SNESOriginalGamesFrame.failure()}
        _=try SNESStartupTrialUSBPolicy.nativeIdentity(device)
        let expected=try SNESStartupTrialExpectation.checked(material.trial)
        let first=try SNESStartupTrialReport(reports[0],expected:expected,challenge:challenges[0])
        let last=try SNESStartupTrialReport(reports[1],expected:expected,challenge:challenges[1])
        guard first.mcpPID==last.mcpPID,first.daemonPID==last.daemonPID else {throw SNESOriginalGamesFrame.failure()}
        let frame=try SNESOriginalGamesFrame(catalog,binding:material.trial.candidate.material.binding,challenge:catalogChallenge)
        let files=["catalog.frame":catalog,"report-0.txt":reports[0],"report-1.txt":reports[1]]
        struct Manifest:Encodable {
            let schemaVersion=1,complete=true,firmwareWritten=false,syncEligible=false,console="snes-usa"
            let operation:UUID,reviewSHA256:String,binding:SNESRuntimeBinding,imageSHA256:String,targetSHA256:String
            let device:RecoveryProbeUSBDevice,catalogChallenge:UUID,challenges:[UUID],gameCount:Int,fileSHA256:[String:String]
        }
        let manifest=Manifest(operation:material.id,reviewSHA256:accepted.reviewSHA256,binding:material.trial.candidate.material.binding,
            imageSHA256:BackupManifest.digest(material.trial.image),targetSHA256:BackupManifest.digest(material.target),device:device,
            catalogChallenge:catalogChallenge,challenges:challenges,gameCount:frame.entries.count,fileSHA256:files.mapValues(BackupManifest.digest))
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try checked.require(material)
        return (files,try encoder.encode(manifest))
    }
    func revalidate() throws {try Task.checkCancellation();try checked.require(accepted.material)}
}

actor SNESOriginalGamesCapture {
    private var busy=false
    func capture(accepted:SNESFirmwareAcceptedInstall,guard checked:SNESFirmwareGuard,io:any SNESOriginalGamesIO) async throws -> SNESOriginalGamesResult {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer {busy=false}
        var closed=false
        let material=accepted.material
        func validate() throws {
            try Task.checkCancellation();try checked.require(material)
            guard accepted.reviewSHA256==checked.reviewSHA256,material.direction == .install else {throw SNESOriginalGamesFrame.failure()}
        }
        do {
            try validate()
            let devices=try await io.inventory();try validate()
            guard devices.count==1,let device=devices.first else {throw SNESOriginalGamesFrame.failure()}
            _=try SNESStartupTrialUSBPolicy.nativeIdentity(device)
            let expectation=try SNESStartupTrialExpectation.checked(material.trial)
            try await io.connect(expected:device);try validate()
            func attachment() async throws {
                guard try await io.inventory()==[device] else {throw SNESOriginalGamesFrame.failure()};try validate()
            }
            try await attachment()
            let firstChallenge=UUID(),first=try await io.report(challenge:firstChallenge);try validate()
            let before=try SNESStartupTrialReport(first,expected:expectation,challenge:firstChallenge)
            try await attachment()
            let catalogChallenge=UUID(),catalog=try await io.originalGames(challenge:catalogChallenge);try validate()
            _=try SNESOriginalGamesFrame(catalog,binding:material.trial.candidate.material.binding,challenge:catalogChallenge)
            try await attachment()
            let lastChallenge=UUID(),last=try await io.report(challenge:lastChallenge);try validate()
            let after=try SNESStartupTrialReport(last,expected:expectation,challenge:lastChallenge)
            guard before.mcpPID==after.mcpPID,before.daemonPID==after.daemonPID else {throw SNESOriginalGamesFrame.failure()}
            try await attachment()
            closed=true;await io.disconnect();try validate()
            return .init(device:device,catalogChallenge:catalogChallenge,catalog:catalog,challenges:[firstChallenge,lastChallenge],reports:[first,last],accepted:accepted,checked:checked)
        } catch {
            if !closed {closed=true;await io.disconnect()}
            throw error
        }
    }
}
