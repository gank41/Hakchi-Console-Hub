import Foundation
import USBBridge

enum SNESOriginalMenuUSBPolicy {
    static let product="Swift Hakchi SNES Original Menu Test"
    static func nativeIdentity(_ d:RecoveryProbeUSBDevice) throws -> hakchi_usb_identity_t {
        guard d.vendorID==0x1f3a,d.productID==0xefe8,d.deviceVersion==0x6a03,d.deviceClass==0,d.product==product,d.locationID != 0,
              let entry=d.registryEntryID,entry>0 else { throw SNESRuntimeBinding.failure() }
        return hakchi_usb_identity_t(registry_entry_id:entry,location_id:d.locationID,vendor_id:d.vendorID,product_id:d.productID,device_version:d.deviceVersion,device_class:d.deviceClass,require_empty_product:false)
    }
    static func after(_ devices:[RecoveryProbeUSBDevice],original:RecoveryProbeUSBDevice) throws -> RecoveryProbeUSBDevice? {
        _=try RecoveryProbePolicy.before([original])
        if devices.isEmpty || devices==[original] { return nil }
        guard devices.count==1,let d=devices.first,d.locationID==original.locationID,d.registryEntryID != original.registryEntryID else { throw SNESRuntimeBinding.failure() }
        _=try nativeIdentity(d);return d
    }
}
protocol SNESOriginalMenuIO: Sendable {
    func inventory() async throws -> [RecoveryProbeUSBDevice]
    func boot(expected:RecoveryProbeUSBDevice) async throws
    func connect(expected:RecoveryProbeUSBDevice) async throws
    func checkpoint(challenge:UUID) async throws -> Data
    func launch(_ request:SNESOriginalMenuLaunchRequest) async throws
    func report(challenge:UUID) async throws -> Data
    func diagnostics() async throws -> Data
    func disconnect() async
}
struct SNESOriginalMenuReadFailure: Error,Sendable { let received:Data,details:Data }
actor SNESOriginalMenuService {
    private enum Outcome { case menu(SNESOriginalMenuResult), capture(SNESStartupCapture) }
    private var busy=false
    private let wait:@Sendable () async throws -> Void
    init(wait:@escaping @Sendable () async throws -> Void={try await Task.sleep(for:.seconds(1))}) {self.wait=wait}
    func start(menu:PreparedSNESOriginalMenu,store:RecoveryBootSnapshotStore,io:any SNESOriginalMenuIO,
               progress:@escaping RecoveryProgressSink={_ in}) async throws -> SNESOriginalMenuResult {
        guard case let .menu(result) = try await run(menu:menu,started:nil,store:store,io:io,progress:progress) else { throw SNESRuntimeBinding.failure() }; return result
    }
    func check(menu:PreparedSNESOriginalMenu,started:SNESOriginalMenuResult,store:RecoveryBootSnapshotStore,io:any SNESOriginalMenuIO,
               progress:@escaping RecoveryProgressSink={_ in}) async throws -> SNESOriginalMenuResult {
        guard case let .menu(result) = try await run(menu:menu,started:started,store:store,io:io,progress:progress) else { throw SNESRuntimeBinding.failure() }; return result
    }
    func captureStartup(menu:PreparedSNESOriginalMenu,store:RecoveryBootSnapshotStore,io:any SNESOriginalMenuIO,
                        progress:@escaping RecoveryProgressSink={_ in}) async throws -> SNESStartupCapture {
        guard case let .capture(result) = try await run(menu:menu,started:nil,store:store,io:io,captureOnly:true,progress:progress) else { throw SNESRuntimeBinding.failure() }; return result
    }
    private func run(menu:PreparedSNESOriginalMenu,started:SNESOriginalMenuResult?,store:RecoveryBootSnapshotStore,io:any SNESOriginalMenuIO,captureOnly:Bool=false,
                     progress:@escaping RecoveryProgressSink) async throws -> Outcome {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
        var stage="source-check",latest=Data(),checkpoint:SNESOriginalMenuCheckpoint?,connected=false,closed=false
        var capturedReports:[Data]=[],capturedDiagnostics=Data()
        func validate() throws {try Task.checkCancellation();try menu.validateCurrent();try Task.checkCancellation()}
        do {
            try validate()
            let before:RecoveryProbeUSBDevice,after:RecoveryProbeUSBDevice
            if let started {
                _=try started.checkedExport(menu:menu)
                guard started.phase=="started" else {throw SNESRuntimeBinding.failure()}
                before=started.checkpoint.before;after=started.checkpoint.after
                checkpoint=started.checkpoint;stage="existing-connection"
                try validate();guard try await io.inventory()==[after] else {throw SNESRuntimeBinding.failure()};try validate()
            } else {
                stage="recovery-connection";await progress(.checkingUSB);try validate()
                let inventory=try await io.inventory();try validate();before=try RecoveryProbePolicy.before(inventory)
                stage="temporary-startup";await progress(.uploadingRecovery);try validate()
                try await io.boot(expected:before);try validate()
                stage="menu-connection";await progress(.waitingForRecovery);try validate()
                var found:RecoveryProbeUSBDevice?
                for _ in 0..<60 {
                    try validate();let devices=try await io.inventory();try validate()
                    found=try SNESOriginalMenuUSBPolicy.after(devices,original:before)
                    if found != nil {break};try await wait();try validate()
                }
                guard let found else {throw SNESRuntimeBinding.failure()};after=found
            }
            try validate();guard try await io.inventory()==[after] else {throw SNESRuntimeBinding.failure()};try validate()
            stage="opening-connection";try await io.connect(expected:after);connected=true;try validate()
            let checkpointDirectory:URL
            if let started {checkpointDirectory=started.checkpointDirectory}
            else {
                stage="pre-menu-checkpoint";let challenge=UUID();await progress(.checkingIdentity);try validate()
                latest=try await io.checkpoint(challenge:challenge);try validate()
                _=try SNESOriginalMenuReport(latest,expected:menu.expectation,challenge:challenge,state:.preMenu)
                let captured=SNESOriginalMenuCheckpoint(before:before,after:after,challenge:challenge,report:latest);checkpoint=captured
                stage="saving-checkpoint";try validate()
                if captureOnly {
                    let directory=try await store.saveSNESOriginalMenuCheckpoint(captured,menu:menu);try validate()
                    stage="capture-diagnostics";capturedDiagnostics=try await io.diagnostics();try validate()
                    let result=SNESStartupCapture(checkpoint:captured,checkpointDirectory:directory,diagnostics:capturedDiagnostics)
                    _=try result.checkedExport(menu:menu)
                    guard try await io.inventory()==[after] else {throw SNESRuntimeBinding.failure()};try validate()
                    stage="closing";await progress(.closing);try validate()
                    closed=true;await io.disconnect();try validate();return .capture(result)
                }
                let request=try await captured.persistForLaunch(menu:menu,store:store);try validate()
                checkpointDirectory=request.checkpointDirectory
                stage="checking-launch-connection"
                guard try await io.inventory()==[after] else {throw SNESRuntimeBinding.failure()};try validate();try request.validateCurrent()
                stage="launching-menu";try await io.launch(request);try validate()
            }
            var reports:[Data]=[],challenges:[UUID]=[]
            for _ in 0..<2 {
                stage="live-menu-report";let challenge=UUID();try validate()
                latest=try await io.report(challenge:challenge);try validate()
                _=try SNESOriginalMenuReport(latest,expected:menu.expectation,challenge:challenge,state:.ready)
                reports.append(latest);capturedReports.append(latest);challenges.append(challenge)
            }
            stage="saving-diagnostics";try validate()
            capturedDiagnostics=try await io.diagnostics();try validate()
            _=try SNESOriginalMenuDiagnostics(capturedDiagnostics,nonce:menu.nonce)
            stage="final-connection-check";try validate()
            guard try await io.inventory()==[after] else {throw SNESRuntimeBinding.failure()};try validate()
            guard let checkpoint else {throw SNESRuntimeBinding.failure()}
            let result=SNESOriginalMenuResult(checkpoint:checkpoint,checkpointDirectory:checkpointDirectory,challenges:challenges,reports:reports,diagnostics:capturedDiagnostics,phase:started == nil ? "started":"after-gameplay")
            _=try result.checkedExport(menu:menu)
            stage="closing";await progress(.closing);try validate()
            closed=true;await io.disconnect();try validate();return .menu(result)
        } catch {
            if let failure=error as? SNESOriginalMenuReadFailure {latest=Data(failure.received.prefix(65536))}
            var details=capturedDiagnostics + ((error as? SNESOriginalMenuReadFailure)?.details ?? Data())
            if connected && !(error is CancellationError) && !Task.isCancelled {
                do {try validate();let more=try await io.diagnostics();details=Data((details+more).prefix(65536))} catch {}
            }
            if !closed {closed=true;await io.disconnect()}
            if error is CancellationError || Task.isCancelled {throw CancellationError()}
            throw SNESOriginalMenuFailure(stage:stage,report:Data(latest.prefix(65536)),diagnostics:Data(details.prefix(65536)),checkpoint:checkpoint,capturedReports:capturedReports)
        }
    }
}
