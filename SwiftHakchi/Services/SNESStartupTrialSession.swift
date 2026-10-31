import Foundation
import USBBridge
import SwiftHakchiCore

enum SNESStartupTrialUSBPolicy {
    static let product="Swift Hakchi SNES Startup"
    static func after(_ devices:[RecoveryProbeUSBDevice],original:RecoveryProbeUSBDevice)throws->RecoveryProbeUSBDevice? {
        _=try RecoveryProbePolicy.before([original])
        if devices.isEmpty || devices==[original] {return nil}
        guard devices.count==1,let d=devices.first,d.locationID==original.locationID,d.registryEntryID != original.registryEntryID else {throw SNESRuntimeBinding.failure()}
        _=try nativeIdentity(d);return d
    }
    static func nativeIdentity(_ d:RecoveryProbeUSBDevice)throws->hakchi_usb_identity_t {
        guard d.vendorID==0x1f3a,d.productID==0xefe8,[UInt16(0x6a04),UInt16(0x6a05),UInt16(0x6a06),UInt16(0x6a07),UInt16(0x6a08),UInt16(0x6a09),UInt16(0x6a0a),UInt16(0x6a0b)].contains(d.deviceVersion),d.deviceClass==0,d.product==product,
              d.locationID != 0,let entry=d.registryEntryID,entry>0 else {throw SNESRuntimeBinding.failure()}
        return hakchi_usb_identity_t(registry_entry_id:entry,location_id:d.locationID,vendor_id:d.vendorID,product_id:d.productID,device_version:d.deviceVersion,device_class:d.deviceClass,require_empty_product:false)
    }
}
protocol SNESStartupTrialIO:Sendable {
    func inventory() async throws -> [RecoveryProbeUSBDevice]
    func boot(expected:RecoveryProbeUSBDevice) async throws
    func connect(expected:RecoveryProbeUSBDevice) async throws
    func report(challenge:UUID) async throws -> Data
    func disconnect() async
}
struct SNESStartupTrialResult:Sendable {
    let before:RecoveryProbeUSBDevice,after:RecoveryProbeUSBDevice,challenges:[UUID],reports:[Data],phase:String
    fileprivate init(before:RecoveryProbeUSBDevice,after:RecoveryProbeUSBDevice,challenges:[UUID],reports:[Data],phase:String) {
        self.before=before;self.after=after;self.challenges=challenges;self.reports=reports;self.phase=phase
    }
    private struct Manifest:Codable {
        let schemaVersion:Int,scope:String,complete:Bool,phase:String
        let firmwareWritten:Bool,firmwareInstallEligible:Bool,firmwareRestoreEligible:Bool,userGameplayConfirmed:Bool,profileWritesPossible:Bool
        let binding:SNESRuntimeBinding,imageSHA256:String,preflightSHA256:String
        let before:RecoveryProbeUSBDevice,after:RecoveryProbeUSBDevice,challenges:[UUID],reportSHA256:[String]
    }
    func checkedExport(trial:PreparedSNESStartupTrial)throws->(files:[String:Data],manifest:Data) {
        try trial.validateCurrent()
        guard ["started","after-gameplay"].contains(phase),challenges.count==2,Set(challenges).count==2,reports.count==2,
              try SNESStartupTrialUSBPolicy.after([after],original:before)==after else {throw SNESRuntimeBinding.failure()}
        let expected=try SNESStartupTrialExpectation.checked(trial)
        for i in 0..<2 {_=try SNESStartupTrialReport(reports[i],expected:expected,challenge:challenges[i])}
        let m=Manifest(schemaVersion:1,scope:"snes-original-profile-startup-trial",complete:true,phase:phase,
            firmwareWritten:false,firmwareInstallEligible:false,firmwareRestoreEligible:false,userGameplayConfirmed:false,profileWritesPossible:true,
            binding:trial.candidate.material.binding,imageSHA256:BackupManifest.digest(trial.image),preflightSHA256:trial.evidence.manifestSHA256,
            before:before,after:after,challenges:challenges,reportSHA256:reports.map(BackupManifest.digest))
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return (["report-0.txt":reports[0],"report-1.txt":reports[1]],try encoder.encode(m))
    }
    static func loadStarted(directory:URL,trial:PreparedSNESStartupTrial)throws->Self {
        let dir=try RestoreDirectory(directory),prefix="SNES-Startup-Trial-Result-"
        guard dir.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil,
              Set(try dir.names())==Set(["manifest.json","report-0.txt","report-1.txt"]) else {throw SNESRuntimeBinding.failure()}
        let raw=try dir.read("manifest.json",maximum:65536),m=try JSONDecoder().decode(Manifest.self,from:raw)
        guard m.phase=="started" else {throw SNESRuntimeBinding.failure()}
        let value=Self(before:m.before,after:m.after,challenges:m.challenges,reports:try (0..<2).map {try dir.read("report-\($0).txt",maximum:16384)},phase:m.phase)
        let checked=try value.checkedExport(trial:trial)
        guard let actual=try JSONSerialization.jsonObject(with:checked.manifest) as? NSDictionary,
              let original=try JSONSerialization.jsonObject(with:raw) as? [String:Any],actual.isEqual(to:original) else {throw SNESRuntimeBinding.failure()}
        try dir.check();return value
    }
}
struct SNESStartupTrialFailure:Error,Sendable,LocalizedError {
    let stage:String,report:Data,reason:String
    init(stage:String,report:Data,reason:String="") {self.stage=stage;self.report=report;self.reason=String(reason.prefix(1024))}
    var errorDescription:String? {"The temporary SNES startup check stopped at \(stage). Nothing was installed."}
    func checkedExport(trial:PreparedSNESStartupTrial)throws->(files:[String:Data],manifest:Data) {
        // A failed source check must not prevent saving inert diagnostic evidence.
        // Use only retained values; this receipt grants no startup or write authority.
        let bytes=Data(report.prefix(16384))
        let raw=try JSONSerialization.data(withJSONObject:["schemaVersion":1,"scope":"snes-startup-trial-diagnostic","complete":false,"firmwareWritten":false,
            "firmwareInstallEligible":false,"firmwareRestoreEligible":false,"bootEligible":false,"stage":String(stage.prefix(128)),"reason":reason,"reportSHA256":BackupManifest.digest(bytes),
            "imageSHA256":BackupManifest.digest(trial.image),"preflightSHA256":trial.evidence.manifestSHA256],options:[.prettyPrinted,.sortedKeys])
        return (bytes.isEmpty ? [:]:["partial-report.bin":bytes],raw)
    }
}
actor SNESStartupTrialService {
    private let wait:@Sendable () async throws -> Void,attempts:Int
    private var busy=false
    init(wait:@escaping @Sendable () async throws -> Void={try await Task.sleep(for:.seconds(1))},attempts:Int=60) {self.wait=wait;self.attempts=min(60,max(1,attempts))}
    func capture(trial:PreparedSNESStartupTrial,started:SNESStartupTrialResult?=nil,io:any SNESStartupTrialIO,progress:@escaping RecoveryProgressSink={_ in}) async throws -> SNESStartupTrialResult {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer {busy=false}
        let validate:@Sendable () throws -> Void={try Task.checkCancellation();try trial.validateCurrent()}
        var closed=false,stage="checking-files",latest=Data()
        do {
            try validate();let expected=try SNESStartupTrialExpectation.checked(trial)
            await progress(.checkingUSB);try validate()
            let before:RecoveryProbeUSBDevice,after:RecoveryProbeUSBDevice
            if let started {
                guard started.phase=="started" else {throw SNESRuntimeBinding.failure()};_=try started.checkedExport(trial:trial)
                before=started.before;after=started.after
                guard try await io.inventory()==[after] else {throw SNESRuntimeBinding.failure()};try validate()
            } else {
                stage="checking-recovery-connection";before=try RecoveryProbePolicy.before(await io.inventory());try validate()
                stage="temporary-startup";await progress(.uploadingRecovery);try validate();try await io.boot(expected:before);try validate()
                stage="waiting-for-startup-connection";await progress(.waitingForRecovery);try validate()
                var found:RecoveryProbeUSBDevice?
                for i in 0..<attempts {
                    let devices=try await io.inventory();try validate()
                    if let device=try SNESStartupTrialUSBPolicy.after(devices,original:before) {found=device;break}
                    if i+1<attempts {try await wait();try validate()}
                }
                guard let found else {throw SNESRuntimeBinding.failure()};after=found
            }
            stage="opening-startup-connection";try await io.connect(expected:after);try validate()
            var reports:[Data]=[],challenges:[UUID]=[]
            for _ in 0..<2 {
                guard try await io.inventory()==[after] else {throw SNESRuntimeBinding.failure()};try validate()
                stage="checking-menu-and-startup";await progress(.checkingIdentity);try validate()
                let id=UUID();latest=try await io.report(challenge:id);try validate()
                _=try SNESStartupTrialReport(latest,expected:expected,challenge:id)
                challenges.append(id);reports.append(latest)
                guard try await io.inventory()==[after] else {throw SNESRuntimeBinding.failure()};try validate()
            }
            let result=SNESStartupTrialResult(before:before,after:after,challenges:challenges,reports:reports,phase:started==nil ? "started":"after-gameplay")
            _=try result.checkedExport(trial:trial);await progress(.closing);closed=true;await io.disconnect();try validate();return result
        } catch {
            if let failure=error as? SNESStartupTrialReadFailure {latest=failure.raw}
            if !closed {closed=true;await io.disconnect()}
            if error is CancellationError || Task.isCancelled {throw CancellationError()}
            throw SNESStartupTrialFailure(stage:stage,report:Data(latest.prefix(16384)),reason:String(describing:error))
        }
    }
}
struct SNESStartupTrialReadFailure:Error,Sendable {let raw:Data}
