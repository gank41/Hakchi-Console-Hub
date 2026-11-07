import Foundation

protocol SNESFirmwareShell: Sendable {
    func executeBounded(_ command: String, stdoutLimit: Int, stderrLimit: Int, timeout: Int) async throws -> BoundedSSHExecution
    func executeFirmwareBounded(_ command:String,stdoutLimit:Int,stderrLimit:Int,timeout:Int,gate:SNESFirmwareDispatchGate) async throws -> BoundedSSHExecution
    func uploadExclusive(data: Data, to remotePath: String, timeout: Int) async throws
}
extension SSHService: SNESFirmwareShell {}

struct SNESFirmwareCommandFailure:Error,Sendable {
    let transport:Int,exit:Int,output:Data,errors:Data
    var diagnostic:String {
        let value:[String:Any]=["transport":transport,"exit":exit,"stdoutBase64":Data(output.prefix(4096)).base64EncodedString(),"stderrBase64":Data(errors.prefix(4096)).base64EncodedString()]
        guard let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else {return "Recovery command diagnostics could not be encoded."}
        return String(decoding:data,as:UTF8.self)
    }
}

/// A read-only, one-use receipt tied to the currently open Native connection.
/// It is not a firmware-write permit and is invalidated on competing operations.
final class SNESReviewedPreflightProof: @unchecked Sendable {
    private let lock=NSLock()
    private let operation:UUID,review:String,reservation:UUID,validateSources:@Sendable () throws -> Void
    private var valid=true,claimed=false
    fileprivate init(operation:UUID,review:String,reservation:UUID,validateSources:@escaping @Sendable () throws -> Void) {
        self.operation=operation;self.review=review;self.reservation=reservation;self.validateSources=validateSources
    }
    func invalidate() {lock.lock();valid=false;lock.unlock()}
    func validate() throws {
        lock.lock();let before=valid;lock.unlock()
        guard before else {throw SNESRuntimeBinding.failure()}
        try Task.checkCancellation();try validateSources()
        lock.lock();let after=valid;lock.unlock()
        guard after else {throw SNESRuntimeBinding.failure()}
        try Task.checkCancellation()
    }
    func consume(operation:UUID,review:String,reservation:UUID,_ checkJournal:() throws -> Void)throws {
        guard self.operation==operation,self.review==review,self.reservation==reservation else {throw SNESRuntimeBinding.failure()}
        try validate()
        lock.lock()
        guard valid,!claimed else {lock.unlock();throw SNESRuntimeBinding.failure()}
        claimed=true;lock.unlock()
        do {try checkJournal();try validate()} catch {invalidate();throw error}
    }
    fileprivate func requireConsumed(operation:UUID,review:String,reservation:UUID)throws {
        guard self.operation==operation,self.review==review,self.reservation==reservation else {throw SNESRuntimeBinding.failure()}
        try validate();lock.lock();let accepted=valid && claimed;lock.unlock()
        guard accepted else {throw SNESRuntimeBinding.failure()};try validate()
    }
}

/// Identity is scoped only around calls made by the transaction connection;
/// progress callbacks do not inherit the owner's access.
enum SNESReviewedSessionContext {
    @TaskLocal static var owner:UUID?
}
final class SNESReviewedSessionLease: @unchecked Sendable {
    private enum State {case active,closing,closed,invalid}
    let id=UUID()
    private let lock=NSLock()
    private var state:State = .active
    private var sourceCheck:(@Sendable () throws -> Void)?
    func bindSources(_ check:@escaping @Sendable () throws -> Void)throws {
        lock.lock();defer {lock.unlock()}
        guard state == .active,sourceCheck == nil else {throw LegacyInspectionError.busy}
        sourceCheck=check
    }
    func invalidate() {lock.lock();if state != .closed {state = .invalid};lock.unlock()}
    func validate() throws {
        lock.lock();let current=state == .active;lock.unlock()
        guard current else {throw LegacyInspectionError.busy}
        try Task.checkCancellation()
    }
    func beginClose() throws {
        lock.lock();defer {lock.unlock()}
        guard state == .active,!Task.isCancelled else {state = .invalid;throw LegacyInspectionError.busy}
        state = .closing
    }
    func finishClose() {lock.lock();if state == .closing {state = .closed};lock.unlock()}
    func requireClosed() throws {
        lock.lock();let current=state == .closed,check=sourceCheck;lock.unlock()
        guard current,let check else {throw LegacyInspectionError.busy}
        try Task.checkCancellation();try check();try Task.checkCancellation()
        lock.lock();let stillClosed=state == .closed;lock.unlock()
        guard stillClosed else {throw LegacyInspectionError.busy}
    }
}
protocol SNESReviewedSessionOwner:Sendable {
    func beginReviewedSession() async throws -> SNESReviewedSessionLease
}
protocol SNESReviewedPreflightIO:Sendable {
    func verifyReviewedPreflight(context:RecoverySessionContext,header:Data,reservation:UUID) async throws -> SNESReviewedPreflightProof
}
protocol SNESReviewedFirmwareWriteIO:SNESReviewedPreflightIO {
    func replaceReviewed(_ permit:SNESFirmwareWritePermit,proof:SNESReviewedPreflightProof,reservation:UUID) async throws
}

/// An owner-scoped read adapter; it cannot boot, reconnect, or write a console.
private actor SNESReviewedPreflightConnection:SNESDataHashIO {
    let base:any SNESActiveBoot2IO,shell:any SNESFirmwareShell,source:SNESPreparationSource,proof:SNESReviewedPreflightProof
    init(base:any SNESActiveBoot2IO,shell:any SNESFirmwareShell,source:SNESPreparationSource,proof:SNESReviewedPreflightProof) {
        self.base=base;self.shell=shell;self.source=source;self.proof=proof
    }
    private func checked<T:Sendable>(_ body:@Sendable () async throws -> T) async throws -> T {
        try proof.validate();let value=try await body();try proof.validate();return value
    }
    func inventory() async throws->[RecoveryProbeUSBDevice] {try await checked {try await self.base.inventory()}}
    func observe() async throws->String {try await checked {try await self.base.observe()}}
    func readPartitions() async throws->Data {try await checked {try await self.base.readPartitions()}}
    func readDataSuperblock() async throws->Data {try await checked {try await self.base.readDataSuperblock()}}
    func dataHash(challenge:UUID) async throws->Data {
        let plan=try source.dataSnapshotPlan()
        let result=try await checked {try await self.shell.executeBounded(SNESDataSnapshotCommands.hash(plan:plan,challenge:challenge),stdoutLimit:256,stderrLimit:16384,timeout:180000)}
        guard result.transportCode==0,result.exitCode==0,result.stdout.count<=256,result.stderr.count<=16384 else {throw SNESRuntimeBinding.failure()}
        _=try SNESDataSnapshotChunk.fullHash(result.stdout,challenge:challenge,count:plan.byteCount)
        return result.stdout
    }
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {throw SNESRuntimeBinding.failure()}
    func connect(expected:RecoveryProbeUSBDevice) async throws {throw SNESRuntimeBinding.failure()}
    func disconnect() async {}
}

/// One recovery connection and one permitted firmware dispatch for its lifetime.
actor NativeSNESFirmwareIO: SNESFirmwareIO, SNESDataHashIO, SNESReviewedFirmwareWriteIO, SNESReviewedSessionOwner {
    private let material: SNESFirmwareMaterial
    private let guardValue: SNESFirmwareGuard
    private let base: any SNESActiveBoot2IO
    private let shell: any SNESFirmwareShell
    private let testLibraryRoot: URL?
    private var closed = false, bootRequested = false, connectRequested = false, ready = false
    private var stageRequested = false, staged = false, verifyRequested = false, verified = false, writeRequested = false
    private var attachment: RecoveryProbeUSBDevice?
    private var hashPartitionsVerified = false, hashHeaderVerified = false
    private var hashInProgress = false
    private var stateGeneration: UInt64 = 0
    private var pendingDispatch:SNESFirmwareDispatchGate?
    private var reviewedPreflight:SNESReviewedPreflightProof?
    private var reviewedWriteActive = false
    private var reviewedSession:SNESReviewedSessionLease?
    private var disconnectTask:Task<Void,Never>?
    private var publicOperations=0

    init(material: SNESFirmwareMaterial, guard guardValue: SNESFirmwareGuard) throws {
        try guardValue.require(material)
        if material.direction == .install { try SNESColdBootPolicy.require(boot1:material.source.boot1,image:material.trial.image) }
        self.material = material; self.guardValue = guardValue
        testLibraryRoot = nil
        let shared = SSHService()
        shell = shared
        base = NativeSNESActiveBoot2IO(source: material.source, helper: material.reader, shell: shared)
    }
    init(material: SNESFirmwareMaterial, guard guardValue: SNESFirmwareGuard, base: any SNESActiveBoot2IO, shell: any SNESFirmwareShell, testLibraryRoot: URL? = nil) throws {
        try guardValue.require(material)
        if material.direction == .install { try SNESColdBootPolicy.require(boot1:material.source.boot1,image:material.trial.image) }
        self.material = material; self.guardValue = guardValue; self.base = base; self.shell = shell; self.testLibraryRoot = testLibraryRoot
    }
    func beginReviewedSession() throws -> SNESReviewedSessionLease {
        try Task.checkCancellation()
        guard material.firstInstall != nil,reviewedSession == nil,reviewedPreflight == nil,pendingDispatch == nil,
              !closed,!bootRequested,!connectRequested,publicOperations == 0 else {throw LegacyInspectionError.busy}
        try guardValue.validate()
        let lease=SNESReviewedSessionLease();reviewedSession=lease;return lease
    }
    private func check() throws {
        guard !closed else { throw LegacyInspectionError.disconnected }
        try reviewedSession?.validate();try guardValue.validate()
    }
    private func checkReviewedOwnership()throws {
        if let reviewedSession, SNESReviewedSessionContext.owner != reviewedSession.id {
            pendingDispatch?.invalidate();reviewedPreflight?.invalidate();reviewedSession.invalidate()
            throw LegacyInspectionError.busy
        }
        try reviewedSession?.validate()
    }
    private func checkPublicEntry()throws {
        try checkReviewedOwnership()
        if let reviewedPreflight {
            guard reviewedWriteActive else {reviewedPreflight.invalidate();throw LegacyInspectionError.busy}
            try reviewedPreflight.validate()
        }
        if let pendingDispatch {pendingDispatch.invalidate();throw LegacyInspectionError.busy}
        try check()
    }
    private func beginPublicOperation()throws {try checkPublicEntry();publicOperations += 1}
    private func endPublicOperation() {publicOperations -= 1}
    private func checked<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try check()
        if reviewedWriteActive {guard let proof=reviewedPreflight else {throw SNESRuntimeBinding.failure()};try proof.validate()}
        let value = try await operation()
        try check()
        if reviewedWriteActive {guard let proof=reviewedPreflight else {throw SNESRuntimeBinding.failure()};try proof.validate()}
        return value
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] {try beginPublicOperation();defer {endPublicOperation()};return try await checked { try await self.base.inventory() } }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws {
        try beginPublicOperation();defer {endPublicOperation()}
        guard !bootRequested, !connectRequested else { throw SNESRuntimeBinding.failure() }
        bootRequested = true
        try await checked { try await self.base.boot(inputs, expected: expected) }
    }
    func connect(expected: RecoveryProbeUSBDevice) async throws {
        try beginPublicOperation();defer {endPublicOperation()}
        guard !connectRequested else { throw SNESRuntimeBinding.failure() }
        stateGeneration &+= 1; hashPartitionsVerified = false; hashHeaderVerified = false
        connectRequested = true
        try await checked { try await self.base.connect(expected: expected) }
        attachment = expected
    }
    func observe() async throws -> String {try beginPublicOperation();defer {endPublicOperation()};return try await checked { try await self.base.observe() } }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read {try beginPublicOperation();defer {endPublicOperation()};return try await checked { try await self.base.readBoot2(slot) } }
    func readBoot1() async throws -> Data {try beginPublicOperation();defer {endPublicOperation()};return try await checked { try await self.base.readBoot1() } }
    func readPartitions() async throws -> Data {
        try beginPublicOperation();defer {endPublicOperation()}
        stateGeneration &+= 1; let generation = stateGeneration
        hashPartitionsVerified = false; hashHeaderVerified = false
        ready = false
        let raw = try await checked { try await self.base.readPartitions() }
        guard generation == stateGeneration else { throw SNESRuntimeBinding.failure() }
        hashPartitionsVerified = raw == material.source.partitions
        return raw
    }
    func readDataSuperblock() async throws -> Data {
        try beginPublicOperation();defer {endPublicOperation()}
        stateGeneration &+= 1; let generation = stateGeneration
        hashHeaderVerified = false
        ready = false
        let raw = try await checked { try await self.base.readDataSuperblock() }
        _ = try material.source.validateHeader(raw)
        guard generation == stateGeneration else { throw SNESRuntimeBinding.failure() }
        hashHeaderVerified = hashPartitionsVerified
        ready = hashHeaderVerified
        return raw
    }
    func geometry(challenge: UUID) async throws -> Data {try beginPublicOperation();defer {endPublicOperation()};return try await checked { try await self.base.geometry(challenge: challenge) } }
    func readActive(challenge: UUID) async throws -> Data {try beginPublicOperation();defer {endPublicOperation()};return try await checked { try await self.base.readActive(challenge: challenge) } }
    private func current() async throws {
        try check()
        guard ready, let expected = attachment else { throw SNESRuntimeBinding.failure() }
        guard try await checked({ try await self.base.inventory() }) == [expected] else { throw SNESRuntimeBinding.failure() }
        let raw = try await checked { try await self.base.observe() }
        try material.source.requireObservation(SNESBackupPolicy.observation(raw))
        guard try await checked({ try await self.base.inventory() }) == [expected],
              ready, attachment == expected else { throw SNESRuntimeBinding.failure() }
        try check()
    }
    /// Read-only comparison support; this does not authorize a firmware write.
    func dataHash(challenge: UUID) async throws -> Data {
        try beginPublicOperation();defer {endPublicOperation()}
        guard ready, hashPartitionsVerified, hashHeaderVerified, !hashInProgress,
              (!stageRequested || staged), (!verifyRequested || verified), !writeRequested else { throw SNESRuntimeBinding.failure() }
        hashInProgress = true; defer { hashInProgress = false }
        let generation = stateGeneration, plan = try material.source.dataSnapshotPlan()
        try await current()
        guard generation == stateGeneration, hashPartitionsVerified, hashHeaderVerified else { throw SNESRuntimeBinding.failure() }
        let result = try await checked {
            try await self.shell.executeBounded(SNESDataSnapshotCommands.hash(plan: plan, challenge: challenge),
                                                stdoutLimit: 256, stderrLimit: 16384, timeout: 180000)
        }
        guard result.transportCode == 0, result.exitCode == 0, result.stdout.count <= 256, result.stderr.count <= 16384 else { throw SNESRuntimeBinding.failure() }
        _ = try SNESDataSnapshotChunk.fullHash(result.stdout, challenge: challenge, count: plan.byteCount)
        try await current()
        guard generation == stateGeneration, hashPartitionsVerified, hashHeaderVerified else { throw SNESRuntimeBinding.failure() }
        return result.stdout
    }
    /// Compare the reviewed backup while exclusively owning this live session.
    /// A returned proof can record preflight only; it cannot authorize writing.
    func verifyReviewedPreflight(context:RecoverySessionContext,header:Data,reservation:UUID) async throws -> SNESReviewedPreflightProof {
        try checkPublicEntry()
        guard let binding=material.firstInstall,reviewedPreflight==nil,pendingDispatch==nil,
              publicOperations==0,ready,staged,verified,!writeRequested,!hashInProgress,
              attachment==context.after else {throw SNESRuntimeBinding.failure()}
        try material.source.requireObservation(context.observation)
        guard let session=reviewedSession,SNESReviewedSessionContext.owner == session.id else {throw SNESRuntimeBinding.failure()}
        let seal=try material.validateReviewedFirstInstall(),sourceGuard=guardValue
        let sourceCheck:@Sendable () throws -> Void = {try sourceGuard.validate();try seal.validate()}
        try session.bindSources(sourceCheck)
        let proof=SNESReviewedPreflightProof(operation:material.id,review:guardValue.reviewSHA256,reservation:reservation,validateSources:{try session.validate();try sourceCheck()})
        reviewedPreflight=proof
        do {
            return try await withTaskCancellationHandler(operation:{
                try proof.validate()
                let package=try SNESDataSnapshotPackage.load(receipt:.init(directory:URL(fileURLWithPath:binding.dataDirectory),manifestSHA256:binding.dataManifestSHA256),source:material.source)
                guard package.sha256==binding.dataSHA256,package.byteCount==binding.dataBytes else {throw SNESRuntimeBinding.failure()}
                let connection=SNESReviewedPreflightConnection(base:base,shell:shell,source:material.source,proof:proof)
                try await SNESDataSnapshotLiveCheck.verify(package:package,source:material.source,context:context,header:header,connection:connection)
                try proof.validate();return proof
            },onCancel:{proof.invalidate()})
        } catch {
            proof.invalidate();reviewedPreflight=nil;throw error
        }
    }
    private func execute(_ command: String, expected: String,gate:SNESFirmwareDispatchGate?=nil) async throws {
        try await current()
        let result = try await checked {
            if let gate {return try await self.shell.executeFirmwareBounded(command,stdoutLimit:512,stderrLimit:16384,timeout:180000,gate:gate)}
            return try await self.shell.executeBounded(command, stdoutLimit: 512, stderrLimit: 16384, timeout: 180000)
        }
        guard result.transportCode == 0, result.exitCode == 0,
              result.stdout == Data(expected.utf8), result.stderr.count <= 16384 else {
            throw SNESFirmwareCommandFailure(transport:result.transportCode,exit:result.exitCode,output:Data(result.stdout.prefix(4096)),errors:Data(result.stderr.prefix(4096)))
        }
    }
    func stage() async throws {
        try beginPublicOperation();defer {endPublicOperation()}
        guard ready, attachment != nil, !stageRequested, !writeRequested, !hashInProgress else { throw SNESRuntimeBinding.failure() }
        stageRequested = true
        try await execute(SNESFirmwareCommands.create(material.id), expected: SNESFirmwareCommands.created(material.id))
        let directory = SNESFirmwareCommands.directory(material.id)
        let payload = material.geometry + material.preimage + material.target
        try await current()
        try await checked { try await self.shell.uploadExclusive(data: self.material.writer.bytes, to: directory + "/writer", timeout: 180000) }
        try await current()
        try await checked { try await self.shell.uploadExclusive(data: payload, to: directory + "/input", timeout: 180000) }
        try await execute(SNESFirmwareCommands.checked(material), expected: SNESFirmwareCommands.staged(material))
        staged = true
    }
    func verifyStaged() async throws {
        try beginPublicOperation();defer {endPublicOperation()}
        guard staged, !verifyRequested, !writeRequested, !hashInProgress else { throw SNESRuntimeBinding.failure() }
        verifyRequested = true
        try await execute(SNESFirmwareCommands.invoke(material, writing: false), expected: SNESFirmwareCommands.marker(material, writing: false))
        verified = true
    }
    func replace(_ permit: SNESFirmwareWritePermit) async throws {
        try checkReviewedOwnership()
        if let reviewedPreflight {reviewedPreflight.invalidate();throw LegacyInspectionError.busy}
        if let pendingDispatch { pendingDispatch.invalidate(); throw LegacyInspectionError.busy }
        guard permit.id == material.id, permit.reviewSHA256 == guardValue.reviewSHA256 else { throw SNESRuntimeBinding.failure() }
        guard !writeRequested else { throw SNESRuntimeBinding.failure() }
        // A recorded write intent is one-shot, even if this attempt fails before dispatch.
        try permit.claim()
        writeRequested = true
        try check()
        guard publicOperations==0, ready, staged, verified, !hashInProgress else { throw SNESRuntimeBinding.failure() }
        let libraryRoot = try testLibraryRoot ?? SNESLibraryJournalPolicy.ensureRoot()
        let libraryLease = try SNESLibraryJournal.firmwareLease(hwid: material.trial.expectedHWID, root: libraryRoot)
        defer { try? libraryLease.closeLease() }
        let sourceGuard=guardValue
        let gate=SNESFirmwareDispatchGate(validate:{try sourceGuard.validate()});pendingDispatch=gate
        defer {pendingDispatch=nil}
        try await withTaskCancellationHandler(operation:{
            try await execute(SNESFirmwareCommands.invoke(material, writing: true),expected:SNESFirmwareCommands.marker(material, writing: true),gate:gate)
            try Task.checkCancellation()
        },onCancel:{_ = gate.invalidate()})
    }
    /// The write is available only to the session which created and consumed this proof.
    func replaceReviewed(_ permit:SNESFirmwareWritePermit,proof:SNESReviewedPreflightProof,reservation:UUID) async throws {
        try checkReviewedOwnership()
        guard reviewedPreflight === proof,pendingDispatch == nil,!reviewedWriteActive,!writeRequested,
              permit.id == material.id,permit.reviewSHA256 == guardValue.reviewSHA256,
              publicOperations == 0,ready,staged,verified,!hashInProgress else {throw SNESRuntimeBinding.failure()}
        try proof.requireConsumed(operation:material.id,review:guardValue.reviewSHA256,reservation:reservation)
        try permit.claim();writeRequested=true
        let libraryRoot=try testLibraryRoot ?? SNESLibraryJournalPolicy.ensureRoot()
        let libraryLease=try SNESLibraryJournal.firmwareLease(hwid:material.trial.expectedHWID,root:libraryRoot)
        defer {try? libraryLease.closeLease()}
        let sourceGuard=guardValue
        let gate=SNESFirmwareDispatchGate(validate:{try proof.validate();try sourceGuard.validate()})
        pendingDispatch=gate;reviewedWriteActive=true
        defer {pendingDispatch=nil}
        do {
            try await withTaskCancellationHandler(operation:{
                try await execute(SNESFirmwareCommands.invoke(material,writing:true),expected:SNESFirmwareCommands.marker(material,writing:true),gate:gate)
                try Task.checkCancellation();try proof.validate()
            },onCancel:{_ = gate.invalidate();proof.invalidate()})
        } catch {proof.invalidate();throw error}
    }
    func disconnect() async {
        let session=reviewedSession
        let owned=session.map {SNESReviewedSessionContext.owner == $0.id} ?? false
        if !owned {session?.invalidate()}
        if let task=disconnectTask {await task.value;return}
        guard !closed else {return}
        if owned,let session {
            do {
                guard let reviewedPreflight else {throw SNESRuntimeBinding.failure()}
                try reviewedPreflight.validate();try session.beginClose()
            } catch {session.invalidate()}
        }
        pendingDispatch?.invalidate();reviewedPreflight?.invalidate()
        stateGeneration &+= 1; hashPartitionsVerified = false; hashHeaderVerified = false
        closed = true; ready = false; attachment = nil
        let target=base
        let task=Task.detached {await target.disconnect()}
        disconnectTask=task
        await task.value
        if owned {session?.finishClose()}
    }
}
