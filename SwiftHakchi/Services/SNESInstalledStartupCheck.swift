import Foundation
import SwiftHakchiCore

protocol SNESInstalledStartupIO:Sendable {
    func inventory() async throws->[RecoveryProbeUSBDevice]
    func connect(expected:RecoveryProbeUSBDevice) async throws
    func report(challenge:UUID) async throws->Data
    func disconnect() async
}
struct SNESInstalledStartupResult:Sendable {
    let device:RecoveryProbeUSBDevice,challenges:[UUID],reports:[Data]
    private let operation:UUID,reviewSHA256:String
    fileprivate init(device:RecoveryProbeUSBDevice,challenges:[UUID],reports:[Data],operation:UUID,reviewSHA256:String) {
        self.device=device;self.challenges=challenges;self.reports=reports;self.operation=operation;self.reviewSHA256=reviewSHA256
    }
    func export()throws->String {
        struct Receipt:Encodable {
            let scope="snes-installed-normal-startup",firmwareWriteRequested=false,userGameplayConfirmed=false
            let operation:UUID,reviewSHA256:String,device:RecoveryProbeUSBDevice,challenges:[UUID],reportsBase64:[String],reportSHA256:[String]
        }
        let receipt=Receipt(operation:operation,reviewSHA256:reviewSHA256,device:device,challenges:challenges,reportsBase64:reports.map{$0.base64EncodedString()},reportSHA256:reports.map(BackupManifest.digest))
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return String(decoding:try encoder.encode(receipt),as:UTF8.self)
    }
}
actor SNESInstalledStartupCheck {
    private var busy=false
    nonisolated static func recordStartupTransition(for phase: SNESFirmwareJournal.Phase) throws -> Bool {
        switch phase {
        case .readbackVerified: return true
        case .startupVerified: return false
        default: throw RestoreDirectory.failure()
        }
    }
    func run(journal:SNESFirmwareJournal,guard checked:SNESFirmwareGuard,io:any SNESInstalledStartupIO) async throws->SNESInstalledStartupResult {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
        var closed=false
        func validate()throws {try Task.checkCancellation();try checked.validate()}
        do {
            try validate()
            let initialPhase = try await journal.phase()
            let recordTransition = try Self.recordStartupTransition(for: initialPhase)
            let material=try await journal.verifiedMaterial(guard:checked)
            guard material.direction == .install else {throw RestoreDirectory.failure()}
            try validate()
            let devices=try await io.inventory();try validate()
            guard devices.count==1,let device=devices.first else {throw SNESRuntimeBinding.failure()}
            _=try SNESStartupTrialUSBPolicy.nativeIdentity(device)
            let expectation=try SNESStartupTrialExpectation.checked(material.trial)
            try await io.connect(expected:device);try validate()
            var reports:[Data]=[],challenges:[UUID]=[]
            for _ in 0..<2 {
                guard try await io.inventory()==[device] else {throw SNESRuntimeBinding.failure()};try validate()
                let challenge=UUID(),raw=try await io.report(challenge:challenge);try validate()
                _=try SNESStartupTrialReport(raw,expected:expectation,challenge:challenge)
                guard try await io.inventory()==[device] else {throw SNESRuntimeBinding.failure()};try validate()
                challenges.append(challenge);reports.append(raw)
            }
            closed=true;await io.disconnect();try validate()
            guard try await journal.phase() == initialPhase else {throw RestoreDirectory.failure()}
            if recordTransition {try await journal.startupVerified()};try validate()
            return .init(device:device,challenges:challenges,reports:reports,operation:material.id,reviewSHA256:checked.reviewSHA256)
        } catch {
            if !closed {closed=true;await io.disconnect()}
            throw error
        }
    }
}
actor NativeSNESInstalledStartupIO:SNESInstalledStartupIO {
    private let base:NativeSNESStartupTrialIO
    init(trial:PreparedSNESStartupTrial){base=NativeSNESStartupTrialIO(trial:trial)}
    func inventory() async throws->[RecoveryProbeUSBDevice]{try await base.inventory()}
    func connect(expected:RecoveryProbeUSBDevice) async throws{try await base.connect(expected:expected)}
    func report(challenge:UUID) async throws->Data{try await base.report(challenge:challenge)}
    func disconnect() async{await base.disconnect()}
}
