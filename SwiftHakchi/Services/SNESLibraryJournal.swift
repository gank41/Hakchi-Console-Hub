import Foundation
import Darwin
import SwiftHakchiCore

/// A scope token requires both its live journal and the actual native backend checks. It is not a shell command.
struct SNESLibraryCopyPermit: Sendable {
    let id: UUID, reviewSHA256: String, challenge: UUID, operation: URL
    private let index: Int, intentSHA256: String, life: SNESLibraryPermitLife
    fileprivate init(id: UUID, reviewSHA256: String, challenge: UUID, operation: URL, index: Int, intentSHA256: String, life: SNESLibraryPermitLife) {
        self.id = id; self.reviewSHA256 = reviewSHA256; self.challenge = challenge; self.operation = operation
        self.index = index; self.intentSHA256 = intentSHA256; self.life = life
    }
    func require(_ plan: SNESLibrarySyncPlan) throws {
        guard plan.purpose == .forward else { throw SNESLibraryJournal.failure() }
        try life.require(); try plan.requireSources()
        guard id == plan.material.menu.id, reviewSHA256 == plan.reviewSHA256 else { throw SNESLibraryJournal.failure() }
        let directory = try RestoreDirectory(operation)
        guard try directory.read("plan.json", maximum: 24 * 1024 * 1024) == plan.data,
              Set(try directory.names()) == Set(["plan.json"] + (0...index).map(SNESLibraryJournal.name)),
              BackupManifest.digest(try directory.read(SNESLibraryJournal.name(index), maximum: 65536)) == intentSHA256 else { throw SNESLibraryJournal.failure() }
        try life.require()
    }
}
/// A separate one-dispatch scope for saving a reviewed menu selection.
struct SNESLibrarySelectionPermit: Sendable {
    let id: UUID, reviewSHA256: String, challenge: UUID, operation: URL, attachment: RecoveryProbeUSBDevice
    private let index: Int, intentSHA256: String, life: SNESLibraryPermitLife
    fileprivate init(id: UUID, reviewSHA256: String, challenge: UUID, operation: URL, attachment: RecoveryProbeUSBDevice,
                     index: Int, intentSHA256: String, life: SNESLibraryPermitLife) {
        self.id = id; self.reviewSHA256 = reviewSHA256; self.challenge = challenge; self.operation = operation; self.attachment = attachment
        self.index = index; self.intentSHA256 = intentSHA256; self.life = life
    }
    func require(_ plan: SNESLibrarySyncPlan, attachment: RecoveryProbeUSBDevice) throws {
        try life.require(); try plan.requireSources()
        guard self.attachment == attachment, id == plan.material.menu.id, reviewSHA256 == plan.reviewSHA256 else { throw SNESLibraryJournal.failure() }
        let directory = try RestoreDirectory(operation)
        guard try directory.read("plan.json", maximum: 24 * 1024 * 1024) == plan.data,
              Set(try directory.names()) == Set(["plan.json"] + (0...index).map(SNESLibraryJournal.name)),
              BackupManifest.digest(try directory.read(SNESLibraryJournal.name(index), maximum: 65536)) == intentSHA256 else { throw SNESLibraryJournal.failure() }
        try life.require()
    }
}
/// Explicit recovery selection scope; a claimed permit cannot dispatch twice.
struct SNESLibraryRollbackPermit:Sendable {
    let id:UUID,reviewSHA256:String,challenge:UUID,operation:URL,attachment:RecoveryProbeUSBDevice
    let expectedStateSHA256:String,allowsPendingRecovery:Bool
    private let index:Int,intentSHA256:String,life:SNESLibraryPermitLife
    fileprivate init(id:UUID,reviewSHA256:String,challenge:UUID,operation:URL,attachment:RecoveryProbeUSBDevice,
                     expectedStateSHA256:String,allowsPendingRecovery:Bool,index:Int,intentSHA256:String,life:SNESLibraryPermitLife) {
        self.id=id;self.reviewSHA256=reviewSHA256;self.challenge=challenge;self.operation=operation;self.attachment=attachment
        self.expectedStateSHA256=expectedStateSHA256;self.allowsPendingRecovery=allowsPendingRecovery;self.index=index;self.intentSHA256=intentSHA256;self.life=life
    }
    func claimDispatch() throws {try life.claimDispatch()}
    func require(_ plan:SNESLibrarySyncPlan,attachment:RecoveryProbeUSBDevice)throws {
        try life.require();try plan.requireSources()
        guard self.attachment==attachment,id==plan.material.menu.id,reviewSHA256==plan.reviewSHA256,SNESDataSnapshotChunk.isDigest(expectedStateSHA256) else {throw SNESLibraryJournal.failure()}
        let d=try RestoreDirectory(operation)
        guard try d.read("plan.json",maximum:24*1024*1024)==plan.data,
              Set(try d.names())==Set(["plan.json"]+(0...index).map(SNESLibraryJournal.name)),
              BackupManifest.digest(try d.read(SNESLibraryJournal.name(index),maximum:65536))==intentSHA256 else {throw SNESLibraryJournal.failure()}
        try life.require()
    }
}
struct SNESLibraryCleanupPermit: Sendable {
    let challenge: UUID, operation: URL
    let reconciliation: SNESLibraryReconciliationPermit
    private let index: Int, intentSHA256: String, names: [String], life: SNESLibraryPermitLife
    fileprivate init(challenge: UUID, operation: URL, index: Int, intentSHA256: String, names: [String], life: SNESLibraryPermitLife, reconciliation: SNESLibraryReconciliationPermit) {
        self.challenge = challenge; self.operation = operation; self.index = index; self.intentSHA256 = intentSHA256; self.names = names; self.life = life; self.reconciliation = reconciliation
    }
    func require(plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation) throws {
        try life.require(); try plan.requireSources(); try scope.validateSources()
        let directory = try RestoreDirectory(operation)
        guard scope.syncReviewSHA256 == plan.reviewSHA256, preview.scopeSHA256 == scope.reviewSHA256,
              try directory.names() == names, try directory.read("plan.json", maximum: 24 * 1024 * 1024) == plan.data,
              try directory.read(SNESLibraryJournal.cleanupName(index, kind: "scope.json"), maximum: 4 * 1024 * 1024) == scope.data,
              try directory.read(SNESLibraryJournal.cleanupName(index, kind: "preview.txt"), maximum: 2 * 1024 * 1024) == preview.raw,
              BackupManifest.digest(try directory.read(SNESLibraryJournal.name(index), maximum: 65536)) == intentSHA256 else { throw SNESLibraryJournal.failure() }
        try life.require()
    }
}
struct SNESLibraryDiscardPermit: Sendable {
    let challenge: UUID, operation: URL, attachment: RecoveryProbeUSBDevice
    let reconciliation: SNESLibraryReconciliationPermit
    private let index: Int, intentSHA256: String, names: [String], life: SNESLibraryPermitLife
    fileprivate init(challenge: UUID, operation: URL, attachment: RecoveryProbeUSBDevice, index: Int, intentSHA256: String,
                     names: [String], life: SNESLibraryPermitLife, reconciliation: SNESLibraryReconciliationPermit) {
        self.challenge = challenge; self.operation = operation; self.attachment = attachment; self.index = index
        self.intentSHA256 = intentSHA256; self.names = names; self.life = life; self.reconciliation = reconciliation
    }
    func claimDispatch() throws { try life.claimDispatch() }
    func require(plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation) throws {
        try life.require(); try scope.validateSources(); try reconciliation.require()
        let directory = try RestoreDirectory(operation)
        guard scope.syncReviewSHA256 == plan.reviewSHA256, preview.scopeSHA256 == scope.reviewSHA256,
              try directory.names() == names, try directory.read("plan.json", maximum: 24 * 1024 * 1024) == plan.data,
              try directory.read(SNESLibraryJournal.discardName(index, kind: "scope.json"), maximum: 4 * 1024 * 1024) == scope.data,
              try directory.read(SNESLibraryJournal.discardName(index, kind: "preview.txt"), maximum: 2 * 1024 * 1024) == preview.raw,
              BackupManifest.digest(try directory.read(SNESLibraryJournal.name(index), maximum: 65536)) == intentSHA256 else { throw SNESLibraryJournal.failure() }
        try life.require()
    }
}
/// Synchronous revocation only; this lock is never held over an await or USB access.
fileprivate final class SNESLibraryPermitLife: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true, dispatched = false
    func require() throws { lock.lock(); defer { lock.unlock() }; guard active else { throw SNESLibraryJournal.failure() } }
    func claimDispatch() throws { lock.lock(); defer { lock.unlock() }; guard active, !dispatched else { throw SNESLibraryJournal.failure() }; dispatched = true }
    func revoke() { lock.lock(); active = false; lock.unlock() }
}

/// Allows only a read-only view excluding this exact, inactive unfinished stage.
struct SNESLibraryReconciliationPermit: Sendable {
    let id: UUID, excludedMenuID: UUID?, hwid: String, operation: URL, reviewSHA256: String
    let allowsIncompleteNamespace: Bool
    private let names: [String], seals: [SNESFirmwareSourceSeal]
    fileprivate init(id: UUID, excludedMenuID: UUID?, hwid: String, operation: URL, reviewSHA256: String, names: [String], seals: [SNESFirmwareSourceSeal], allowsIncompleteNamespace: Bool) {
        self.allowsIncompleteNamespace = allowsIncompleteNamespace
        self.id = id; self.excludedMenuID = excludedMenuID; self.hwid = hwid; self.operation = operation; self.reviewSHA256 = reviewSHA256; self.names = names; self.seals = seals
    }
    func require() throws {
        let directory = try RestoreDirectory(operation)
        guard try directory.names() == names else { throw SNESLibraryJournal.failure() }
        for seal in seals { try seal.validate() }
        guard try directory.names() == names else { throw SNESLibraryJournal.failure() }
    }
    func requireOwner(_ context: SNESLibraryContext) throws {
        try require(); try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard context.supportsLibraryRecovery, context.installation.expected.hwid == hwid else { throw SNESLibraryInstallation.failure() }
    }
}

/// A bounded Mac history reference; reopening still verifies every saved payload.
struct SNESLibrarySnapshotReference: Codable, Equatable, Sendable {
    let directory: URL, manifestSHA256: String, snapshotSHA256: String
    init(_ backup: SNESLibraryBackup) throws {
        try backup.validate(); directory = backup.directory; manifestSHA256 = backup.manifestSHA256; snapshotSHA256 = backup.inventory.snapshotSHA256
        try validateMetadata()
    }
    func validateMetadata() throws {
        guard directory.isFileURL, directory == directory.standardizedFileURL, directory.path.hasPrefix("/"), directory.path.utf8.count <= 4096,
              directory.query == nil, directory.fragment == nil, directory.lastPathComponent.hasPrefix("SNES-Library-"),
              let id = UUID(uuidString: String(directory.lastPathComponent.dropFirst("SNES-Library-".count))),
              directory.lastPathComponent == "SNES-Library-" + id.uuidString,
              [manifestSHA256, snapshotSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest) else { throw SNESLibraryJournal.failure() }
    }
    func reopen() throws -> SNESLibraryBackup {
        try validateMetadata(); let value = try SNESLibraryBackup.open(directory: directory)
        guard value.manifestSHA256 == manifestSHA256, value.inventory.snapshotSHA256 == snapshotSHA256 else { throw SNESLibraryJournal.failure() }
        return value
    }
}
enum SNESLibraryJournalPolicy {
    static func root() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw SNESLibraryJournal.failure() }
        return support.appendingPathComponent("SwiftHakchi/LibraryTransactions/SNES", isDirectory: true).standardizedFileURL
    }
    static func ensureRoot() throws -> URL {
        let url = try root(); guard url == url.resolvingSymlinksInPath() else { throw SNESLibraryJournal.failure() }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try RestoreDirectory(url).url
    }
    static func requireOperation(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL == url, url.deletingLastPathComponent().path == (try root()).path,
              let id = UUID(uuidString: String(url.lastPathComponent.dropFirst("SNESLibrarySync-".count))),
              url.lastPathComponent == "SNESLibrarySync-" + id.uuidString else { throw SNESLibraryJournal.failure() }
    }
}

/// Mac-only intent storage; native copying, selection and cleanup are implemented separately.
actor SNESLibraryJournal {
    enum Phase: String, Codable, Sendable { case prepared, copyIntent, copyUncertain, copied, selectionIntent, selectionUncertain, awaitingRestart, awaitingTest, accepted, cleanupIntent, cleanupUncertain, discardIntent, discardUncertain, finished, discarded, rollbackIntent, rollbackUncertain, rollbackAwaitingRestart, rolledBack }
    struct Prepared: Sendable { let operation: URL, reviewSHA256: String }
    private struct Cleanup: Codable, Equatable { let scopeSHA256: String, previewSHA256: String, index: Int; var kind: String? = nil }
    private struct Record: Codable {
        let phase: Phase, planSHA256: String, previousSHA256: String?, challenge: UUID?
        var evidenceSHA256: String? = nil
        var attachment: RecoveryProbeUSBDevice? = nil
        var backupReference: SNESLibrarySnapshotReference? = nil
        var cleanup: Cleanup? = nil
    }
    private struct State { let phase: Phase, count: Int, lastSHA256: String, challenge: UUID?, attachment: RecoveryProbeUSBDevice?, backupReference: SNESLibrarySnapshotReference?, cleanup: Cleanup? }
    private let storage: RestoreJournalStorage, plan: SNESLibrarySyncPlan
    private var life = SNESLibraryPermitLife()
    private let operation: URL
    private static let prefix = "SNESLibrarySync-"
    static func failure() -> RecoveryProbeError {
        .refused("An unfinished console change needs to be checked before starting another. Open the sync review to continue.")
    }
    static func name(_ index: Int) -> String { String(format: "%04d.json", index) }
    init(operation: URL, reviewSHA256: String, plan: SNESLibrarySyncPlan, synchronize:@escaping @Sendable(Int32)->Int32={Darwin.fsync($0)}) throws {
        guard reviewSHA256 == plan.reviewSHA256, operation.lastPathComponent == Self.prefix + plan.material.menu.id.uuidString else { throw Self.failure() }
        let storage = try RestoreJournalStorage(root: operation.deletingLastPathComponent(), operation: operation,synchronize:synchronize)
        guard try storage.operation!.read("plan.json", maximum: 24 * 1024 * 1024) == plan.data else { throw Self.failure() }
        try Self.checkOthers(storage, excluding: operation.lastPathComponent, hwid: plan.before.hwid)
        _ = try Self.load(storage.operation!, review: reviewSHA256)
        self.storage = storage; self.plan = plan; self.operation = storage.operation!.url
    }
    deinit { life.revoke() }
    static func prepare(plan: SNESLibrarySyncPlan, root: URL) throws -> Prepared {
        try plan.requireSources()
        let storage = try RestoreJournalStorage(root: root); defer { try? storage.closeLease() }
        try checkOthers(storage, excluding: nil, hwid: plan.before.hwid)
        let leaf = prefix + plan.material.menu.id.uuidString
        guard mkdirat(storage.root.fd, leaf, 0o700) == 0 else { throw failure() }
        let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(leaf))
        try storage.write(plan.data, name: "plan.json", directory: directory)
        try storage.write(encode(Record(phase: .prepared, planSHA256: plan.reviewSHA256, previousSHA256: nil, challenge: nil)), name: name(0), directory: directory)
        try storage.sync(directory); try storage.sync(storage.root)
        return .init(operation: directory.url, reviewSHA256: plan.reviewSHA256)
    }
    /// Hold this Mac lease through a firmware dispatch, preventing library preparation from racing it.
    static func firmwareLease(hwid: String, root: URL) throws -> RestoreJournalStorage {
        guard hwid.count == 32, SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }) else { throw failure() }
        let storage = try RestoreJournalStorage(root: root)
        do { try checkOthers(storage, excluding: nil, hwid: hwid); return storage }
        catch { try? storage.closeLease(); throw error }
    }
    /// Keep referenced Mac snapshots available while a console change is unfinished. Caller retains this lease through removal.
    static func backupDeletionLease(directory: URL, root: URL) throws -> RestoreJournalStorage {
        let storage = try RestoreJournalStorage(root: root)
        do {
            let names = try storage.root.names().filter { $0.hasPrefix(prefix) }
            guard names.count <= 256 else { throw failure() }
            for name in names {
                let folder = try RestoreDirectory(storage.root.url.appendingPathComponent(name)), raw = try folder.read("plan.json", maximum: 24 * 1024 * 1024)
                let identity = try SNESLibrarySyncPlan.identity(data: raw), state = try load(folder, review: BackupManifest.digest(raw))
                guard name == prefix + identity.id.uuidString else { throw failure() }
                if ![.finished, .discarded].contains(state.phase),
                   identity.backupDirectory.path == directory.path || state.backupReference?.directory.path == directory.path {
                    throw RecoveryProbeError.refused("Finish or cancel the unfinished sync before removing this backup. It is still needed for recovery.")
                }
            }
            return storage
        } catch { try? storage.closeLease(); throw error }
    }
    static func reconciliation(operation: URL, reviewSHA256: String) throws -> SNESLibraryReconciliationPermit {
        guard SNESDataSnapshotChunk.isDigest(reviewSHA256) else { throw failure() }
        let storage = try RestoreJournalStorage(root: operation.deletingLastPathComponent(), operation: operation)
        defer { try? storage.closeLease() }
        return try makeReconciliation(storage.operation!, reviewSHA256: reviewSHA256)
    }
    /// Inspect an interrupted operation while retaining this actor's exclusive lease.
    func reconciliation() throws -> SNESLibraryReconciliationPermit {
        _ = try state()
        return try Self.makeReconciliation(storage.operation!, reviewSHA256: plan.reviewSHA256)
    }
    private static func makeReconciliation(_ directory: RestoreDirectory, reviewSHA256: String) throws -> SNESLibraryReconciliationPermit {
        let raw = try directory.read("plan.json", maximum: 24 * 1024 * 1024)
        guard BackupManifest.digest(raw) == reviewSHA256 else { throw failure() }
        let identity = try SNESLibrarySyncPlan.identity(data: raw), state = try load(directory, review: reviewSHA256)
        guard directory.url.lastPathComponent == prefix + identity.id.uuidString, [.copyIntent, .copyUncertain, .copied, .discardIntent, .discardUncertain, .selectionIntent, .selectionUncertain, .cleanupIntent, .cleanupUncertain, .accepted, .rolledBack].contains(state.phase) else { throw failure() }
        let names = try directory.names(); var seals: [SNESFirmwareSourceSeal] = []
        for start in stride(from: 0, to: names.count, by: 16) {
            seals.append(try .capture(directories: [], files: names[start..<min(start+16, names.count)].map { directory.url.appendingPathComponent($0) }))
        }
        guard try directory.read("plan.json", maximum: 24 * 1024 * 1024) == raw else { throw failure() }
        _ = try load(directory, review: reviewSHA256)
        let cleanup = [.accepted, .cleanupIntent, .cleanupUncertain].contains(state.phase)
        let excluded = cleanup ? (identity.oldKind == .library ? identity.oldID : nil) : identity.id
        let permit = SNESLibraryReconciliationPermit(id: identity.id, excludedMenuID: excluded, hwid: identity.hwid, operation: directory.url,
            reviewSHA256: reviewSHA256, names: names, seals: seals,
            allowsIncompleteNamespace: !identity.namespaceReady && [.copyIntent, .copyUncertain, .copied, .discardIntent, .discardUncertain].contains(state.phase))
        try permit.require(); return permit
    }
    struct Pending: Sendable {
        let operation: URL, reviewSHA256: String, phase: Phase, menuID: UUID, backupReference: SNESLibrarySnapshotReference?
    }
    /// Metadata-only status. This neither opens USB nor issues a mutation permit.
    static func pending(root: URL, hwid: String) throws -> Pending? {
        guard hwid.count == 32, SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }) else { throw failure() }
        let storage = try RestoreJournalStorage(root: root); defer { try? storage.closeLease() }
        let names = try storage.root.names().filter { $0.hasPrefix(prefix) }.sorted()
        guard names.count <= 256 else { throw failure() }
        var found: Pending?
        for name in names {
            let directory = try RestoreDirectory(root.appendingPathComponent(name)), raw = try directory.read("plan.json", maximum: 24 * 1024 * 1024)
            let identity = try SNESLibrarySyncPlan.identity(data: raw), review = BackupManifest.digest(raw)
            guard name == prefix + identity.id.uuidString else { throw failure() }
            let state = try load(directory, review: review)
            if identity.hwid == hwid, ![.finished, .discarded].contains(state.phase) {
                guard found == nil else { throw failure() }
                found = .init(operation: directory.url, reviewSHA256: review, phase: state.phase, menuID: identity.id, backupReference: state.backupReference)
            }
        }
        return found
    }
    /// A prepared record proves no console dispatch was permitted. Editable inputs need not still exist.
    static func closeUnsentReview(operation: URL, reviewSHA256: String) throws {
        let storage = try RestoreJournalStorage(root: operation.deletingLastPathComponent(), operation: operation)
        defer { try? storage.closeLease() }
        let directory = storage.operation!, raw = try directory.read("plan.json", maximum: 24 * 1024 * 1024)
        guard BackupManifest.digest(raw) == reviewSHA256 else { throw failure() }
        let identity = try SNESLibrarySyncPlan.identity(data: raw), previous = try load(directory, review: reviewSHA256)
        guard operation.lastPathComponent == prefix + identity.id.uuidString, previous.phase == .prepared else { throw failure() }
        let record = Record(phase: .discarded, planSHA256: reviewSHA256, previousSHA256: previous.lastSHA256, challenge: nil)
        try storage.write(encode(record), name: name(previous.count), directory: directory); try storage.sync(directory)
    }
    /// Read-only reconciliation of a complete inactive stage. Selection remains a separate live native action.
    func recordInspectedCopy(_ inventory: SNESLibraryInventory, now: Date = Date()) throws {
        let previous = try state(); try plan.requireSources()
        guard [.copyIntent, .copyUncertain, .selectionIntent, .selectionUncertain].contains(previous.phase),
              (0...60).contains(now.timeIntervalSince(inventory.capacity.measuredAt)) else { throw Self.failure() }
        try SNESLibraryInactiveCheck.require(plan, inventory: inventory)
        _ = try append(.copied, challenge: nil, evidenceSHA256: BackupManifest.digest(inventory.rawFrame))
        life.revoke()
    }
    nonisolated var rollbackOperation:URL {operation}
    func phase() throws -> Phase { try state().phase }
    func beginCopy() throws -> SNESLibraryCopyPermit {
        let value = try state(); guard plan.purpose == .forward, value.phase == .prepared else { throw Self.failure() }
        try plan.requireSources(); let challenge = UUID()
        let hash = try append(.copyIntent, challenge: challenge)
        return .init(id: plan.material.menu.id, reviewSHA256: plan.reviewSHA256, challenge: challenge, operation: operation,
            index: value.count, intentSHA256: hash, life: life)
    }
    func copyUncertain() throws {
        guard try state().phase == .copyIntent else { throw Self.failure() }
        life.revoke(); _ = try append(.copyUncertain, challenge: nil)
    }
    func noteCopied(_ result: SNESLibraryCopyResult) throws {
        let prior = try state()
        try life.require(); try plan.requireSources()
        guard prior.phase == .copyIntent, result.reviewSHA256 == plan.reviewSHA256, result.challenge == prior.challenge,
              SNESDataSnapshotChunk.isDigest(result.evidenceSHA256) else { throw Self.failure() }
        _ = try append(.copied, challenge: nil, evidenceSHA256: result.evidenceSHA256)
        life.revoke()
    }
    func beginRollback(current:SNESLibraryInventory,attachment:RecoveryProbeUSBDevice,now:Date=Date())throws->SNESLibraryRollbackPermit {
        let prior=try state();try plan.requireSources()
        guard [.selectionUncertain,.awaitingRestart,.awaitingTest,.rollbackUncertain].contains(prior.phase),
              attachment.deviceVersion==plan.requiredUSBVersion,(0...60).contains(now.timeIntervalSince(current.capacity.measuredAt)) else {throw Self.failure()}
        _=try SNESStartupTrialUSBPolicy.nativeIdentity(attachment)
        try SNESLibraryActiveCheck.require(plan,inventory:current,preserveProfiles:false)
        let challenge=UUID(),hash=try append(.rollbackIntent,challenge:challenge,evidenceSHA256:current.stateSHA256,attachment:attachment)
        life.revoke();life=SNESLibraryPermitLife()
        return .init(id:plan.material.menu.id,reviewSHA256:plan.reviewSHA256,challenge:challenge,operation:operation,attachment:attachment,
                     expectedStateSHA256:current.stateSHA256,allowsPendingRecovery:prior.phase == .rollbackUncertain,index:prior.count,intentSHA256:hash,life:life)
    }
    func rollbackUncertain()throws {
        let previous=try state()
        guard previous.phase == .rollbackIntent,let attachment=previous.attachment else {throw Self.failure()}
        life.revoke();_=try append(.rollbackUncertain,challenge:nil,attachment:attachment)
    }
    func noteRollbackSaved(_ receipt:SNESLibraryRollbackReceipt)throws {
        let previous=try state();try life.require();try plan.requireSources()
        let selected=Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(plan.material.menu.id.uuidString)\n\(plan.wireSHA256)\n".utf8)
        guard previous.phase == .rollbackIntent,let attachment=previous.attachment,
              receipt.challenge==previous.challenge,receipt.id==plan.material.menu.id,receipt.hwid==plan.before.hwid,
              receipt.previousSHA256==plan.before.selection.selectorSHA256,receipt.currentSHA256==BackupManifest.digest(selected) else {throw Self.failure()}
        _=try append(.rollbackAwaitingRestart,challenge:nil,evidenceSHA256:BackupManifest.digest(receipt.raw),attachment:attachment)
        life.revoke()
    }
    func rollbackAttachment()throws->RecoveryProbeUSBDevice {
        let value=try state()
        guard [.rollbackIntent,.rollbackUncertain,.rollbackAwaitingRestart].contains(value.phase),let attachment=value.attachment else {throw Self.failure()}
        return attachment
    }
    func noteRolledBack(_ evidence:SNESLibraryColdEvidence)throws {
        let previous=try state();try plan.requireSources()
        guard [.rollbackIntent,.rollbackUncertain,.rollbackAwaitingRestart].contains(previous.phase),
              evidence.destination == .previous,previous.attachment==evidence.previousAttachment,evidence.reviewSHA256==plan.reviewSHA256,
              SNESDataSnapshotChunk.isDigest(evidence.evidenceSHA256) else {throw Self.failure()}
        try SNESLibraryPreviousCheck.require(plan,inventory:evidence.inventory)
        _=try append(.rolledBack,challenge:nil,evidenceSHA256:evidence.evidenceSHA256,attachment:evidence.attachment)
        life.revoke()
    }
    func beginShow(attachment: RecoveryProbeUSBDevice) throws -> SNESLibrarySelectionPermit {
        let previous = try state()
        guard [UInt16(0x6a07),UInt16(0x6a0b)].contains(plan.requiredUSBVersion), previous.phase == .copied, attachment.deviceVersion == plan.requiredUSBVersion else { throw Self.failure() }
        _ = try SNESStartupTrialUSBPolicy.nativeIdentity(attachment)
        try plan.requireSources()
        let challenge = UUID(), hash = try append(.selectionIntent, challenge: challenge, attachment: attachment)
        life.revoke(); life = SNESLibraryPermitLife()
        return .init(id: plan.material.menu.id, reviewSHA256: plan.reviewSHA256, challenge: challenge, operation: operation,
            attachment: attachment, index: previous.count, intentSHA256: hash, life: life)
    }
    func selectionUncertain() throws {
        let previous = try state(); guard previous.phase == .selectionIntent, let attachment = previous.attachment else { throw Self.failure() }
        life.revoke(); _ = try append(.selectionUncertain, challenge: nil, attachment: attachment)
    }
    func noteSelectionSaved(_ receipt: SNESLibrarySelectionReceipt) throws {
        let previous = try state(); try life.require(); try plan.requireSources()
        let selector = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(plan.material.menu.id.uuidString)\n\(plan.wireSHA256)\n".utf8)
        guard previous.phase == .selectionIntent, let attachment = previous.attachment, receipt.id == plan.material.menu.id,
              receipt.challenge == previous.challenge, receipt.selectorSHA256 == BackupManifest.digest(selector),
              receipt.wireSHA256 == plan.wireSHA256, receipt.previousSHA256 == plan.before.selection.selectorSHA256,
              receipt.hwid == plan.before.hwid else { throw Self.failure() }
        _ = try append(.awaitingRestart, challenge: nil, evidenceSHA256: BackupManifest.digest(receipt.raw), attachment: attachment)
        life.revoke()
    }
    func restartAttachment() throws -> RecoveryProbeUSBDevice {
        let value = try state()
        guard [.selectionIntent, .selectionUncertain, .awaitingRestart, .awaitingTest].contains(value.phase), let attachment = value.attachment else { throw Self.failure() }
        return attachment
    }
    func noteRestarted(_ evidence: SNESLibraryColdEvidence) throws {
        let previous = try state(); try plan.requireSources()
        guard evidence.destination == .updated,[.selectionIntent, .selectionUncertain, .awaitingRestart, .awaitingTest].contains(previous.phase),
              previous.attachment == evidence.previousAttachment, evidence.reviewSHA256 == plan.reviewSHA256,
              SNESDataSnapshotChunk.isDigest(evidence.evidenceSHA256) else { throw Self.failure() }
        try SNESLibraryActiveCheck.require(plan, inventory: evidence.inventory, preserveProfiles: false)
        _ = try append(.awaitingTest, challenge: nil, evidenceSHA256: evidence.evidenceSHA256, attachment: evidence.attachment)
        life.revoke()
    }
    /// Called only after the user's gameplay confirmation; it grants no deletion permission.
    func accept(backup: SNESLibraryBackup, originals: SNESOriginalGamesFrame, current: SNESLibraryInventory) throws {
        let previous = try state(); try plan.requireSources(); try backup.validate()
        guard [.awaitingTest, .accepted, .cleanupUncertain].contains(previous.phase), let attachment = previous.attachment,
              backup.inventory.snapshotSHA256 == current.snapshotSHA256, backup.inventory.hwid == plan.before.hwid,
              try SNESLibraryCatalogIdentity.digest(originals) == plan.before.catalogSHA256 else { throw Self.failure() }
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: current, backup: backup, originals: originals)
        try scope.requireCurrent(plan, inventory: current)
        _ = try SNESLibraryRestore.prepare(backup: backup, originals: originals, expectedHWID: plan.before.hwid)
        let reference = try SNESLibrarySnapshotReference(backup)
        _ = try append(.accepted, challenge: nil, evidenceSHA256: BackupManifest.digest(try SNESLibraryMenu.encode(reference)),
            attachment: attachment, backupReference: reference)
        life.revoke()
    }
    func beginCleanup(scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation, now: Date = Date()) throws -> SNESLibraryCleanupPermit {
        let previous = try state()
        try plan.requireSources(); try scope.validateSources()
        guard [.accepted, .cleanupUncertain].contains(previous.phase), let attachment = previous.attachment,
              previous.backupReference == scope.backupReference, scope.syncReviewSHA256 == plan.reviewSHA256,
              preview.scopeSHA256 == scope.reviewSHA256, now.timeIntervalSince(preview.measuredAt) >= 0,
              now.timeIntervalSince(preview.measuredAt) <= 60 else { throw Self.failure() }
        let challenge = UUID(), cleanup = Cleanup(scopeSHA256: scope.reviewSHA256, previewSHA256: BackupManifest.digest(preview.raw), index: previous.count)
        let hash = try append(.cleanupIntent, challenge: challenge, attachment: attachment, backupReference: scope.backupReference, cleanup: cleanup)
        // Durable intent precedes auxiliaries. Missing auxiliaries after a crash grant no dispatch permission.
        try storage.write(scope.data, name: Self.cleanupName(previous.count, kind: "scope.json"), directory: storage.operation!)
        try storage.write(preview.raw, name: Self.cleanupName(previous.count, kind: "preview.txt"), directory: storage.operation!)
        try storage.sync(storage.operation!)
        life.revoke(); life = SNESLibraryPermitLife()
        return .init(challenge: challenge, operation: operation, index: previous.count, intentSHA256: hash,
            names: try storage.operation!.names(), life: life, reconciliation: try Self.makeReconciliation(storage.operation!, reviewSHA256: plan.reviewSHA256))
    }
    func cleanupUncertain() throws {
        let previous = try state()
        guard previous.phase == .cleanupIntent, let cleanup = previous.cleanup, let attachment = previous.attachment,
              let backup = previous.backupReference else { throw Self.failure() }
        life.revoke()
        _ = try append(.cleanupUncertain, challenge: nil, attachment: attachment, backupReference: backup, cleanup: cleanup)
    }
    func finishCleanup(scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation, receipt: SNESLibraryCleanupReceipt,
                       after: SNESLibraryCleanupObservation, inventory: SNESLibraryInventory) throws {
        let previous = try state(); try life.require(); try plan.requireSources(); try scope.validateSources()
        guard previous.phase == .cleanupIntent, let cleanup = previous.cleanup,
              cleanup.scopeSHA256 == scope.reviewSHA256, cleanup.previewSHA256 == BackupManifest.digest(preview.raw),
              previous.challenge == receipt.challenge, receipt.scopeSHA256 == scope.reviewSHA256,
              receipt.previewSHA256 == cleanup.previewSHA256, receipt.contextSHA256 == preview.contextSHA256,
              after.contextSHA256 == preview.contextSHA256, after.scopeSHA256 == scope.reviewSHA256, after.allGone,
              previous.backupReference == scope.backupReference else { throw Self.failure() }
        guard try storage.operation!.read(Self.cleanupName(cleanup.index, kind: "scope.json"), maximum: 4 * 1024 * 1024) == scope.data,
              try storage.operation!.read(Self.cleanupName(cleanup.index, kind: "preview.txt"), maximum: 2 * 1024 * 1024) == preview.raw else { throw Self.failure() }
        try scope.requireCurrent(plan, inventory: inventory)
        let evidence = BackupManifest.digest(receipt.raw + after.raw + inventory.rawFrame)
        _ = try append(.finished, challenge: nil, evidenceSHA256: evidence, attachment: previous.attachment,
            backupReference: previous.backupReference, cleanup: cleanup)
        life.revoke()
    }
    /// Resolve an already-completed removal from fresh read-only evidence, without granting a deletion permit.
    func recordInspectedCleanup(scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation,
                                inventory: SNESLibraryInventory, now: Date = Date()) throws {
        let previous = try state(); try plan.requireSources(); try scope.validateSources()
        guard [.accepted, .cleanupIntent, .cleanupUncertain].contains(previous.phase),
              previous.backupReference == scope.backupReference, scope.syncReviewSHA256 == plan.reviewSHA256,
              preview.scopeSHA256 == scope.reviewSHA256, preview.allGone,
              preview.contextSHA256 == inventory.contextSHA256,
              (0...60).contains(now.timeIntervalSince(preview.measuredAt)),
              (0...60).contains(now.timeIntervalSince(inventory.capacity.measuredAt)),
              scope.retiredObjects.allSatisfy({ inventory.capacity.objects[$0] == nil }),
              scope.oldMenuKind != .library || !inventory.menus.contains(where: { $0.id == scope.oldMenuID }) else { throw Self.failure() }
        try scope.requireCurrent(plan, inventory: inventory)
        let evidence = BackupManifest.digest(scope.data + preview.raw + inventory.rawFrame)
        _ = try append(.finished, challenge: nil, evidenceSHA256: evidence, attachment: previous.attachment,
            backupReference: previous.backupReference, cleanup: previous.cleanup)
        life.revoke()
    }
    func beginDiscard(scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation,
                      attachment: RecoveryProbeUSBDevice, now: Date = Date()) throws -> SNESLibraryDiscardPermit {
        let previous = try state(); try scope.validateSources()
        guard [.copyIntent, .copyUncertain, .copied, .selectionIntent, .selectionUncertain, .discardUncertain, .rolledBack].contains(previous.phase),
              attachment.deviceVersion == plan.requiredUSBVersion, scope.syncReviewSHA256 == plan.reviewSHA256,
              preview.scopeSHA256 == scope.reviewSHA256, (0...60).contains(now.timeIntervalSince(preview.measuredAt)) else { throw Self.failure() }
        _ = try SNESStartupTrialUSBPolicy.nativeIdentity(attachment)
        let challenge = UUID(), cleanup = Cleanup(scopeSHA256: scope.reviewSHA256, previewSHA256: BackupManifest.digest(preview.raw), index: previous.count, kind: "discard")
        let hash = try append(.discardIntent, challenge: challenge, attachment: attachment, cleanup: cleanup)
        try storage.write(scope.data, name: Self.discardName(previous.count, kind: "scope.json"), directory: storage.operation!)
        try storage.write(preview.raw, name: Self.discardName(previous.count, kind: "preview.txt"), directory: storage.operation!)
        try storage.sync(storage.operation!)
        life.revoke(); life = SNESLibraryPermitLife()
        return .init(challenge: challenge, operation: operation, attachment: attachment, index: previous.count, intentSHA256: hash,
            names: try storage.operation!.names(), life: life, reconciliation: try Self.makeReconciliation(storage.operation!, reviewSHA256: plan.reviewSHA256))
    }
    func discardUncertain() throws {
        let previous = try state()
        guard previous.phase == .discardIntent, let cleanup = previous.cleanup, cleanup.kind == "discard" else { throw Self.failure() }
        life.revoke(); _ = try append(.discardUncertain, challenge: nil, attachment: previous.attachment, cleanup: cleanup)
    }
    func finishDiscard(scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation, receipt: SNESLibraryCleanupReceipt,
                       after: SNESLibraryCleanupObservation, inventory: SNESLibraryInventory, now: Date = Date()) throws {
        let previous = try state(); try life.require(); try scope.validateSources()
        guard previous.phase == .discardIntent, let cleanup = previous.cleanup, cleanup.kind == "discard",
              cleanup.scopeSHA256 == scope.reviewSHA256, cleanup.previewSHA256 == BackupManifest.digest(preview.raw),
              previous.challenge == receipt.challenge, receipt.scopeSHA256 == scope.reviewSHA256,
              receipt.previewSHA256 == cleanup.previewSHA256, receipt.contextSHA256 == preview.contextSHA256,
              after.contextSHA256 == preview.contextSHA256, after.scopeSHA256 == scope.reviewSHA256, after.allGone,
              inventory.contextSHA256 == preview.contextSHA256, (0...60).contains(now.timeIntervalSince(after.measuredAt)),
              (0...60).contains(now.timeIntervalSince(inventory.capacity.measuredAt)),
              scope.retiredObjects.allSatisfy({ inventory.capacity.objects[$0] == nil }),
              !inventory.menus.contains(where: { $0.id == scope.retiredMenuID }),
              !scope.retireNamespace || (!inventory.capacity.namespaceReady && !inventory.incompleteNamespace) else { throw Self.failure() }
        guard try storage.operation!.read(Self.discardName(cleanup.index, kind: "scope.json"), maximum: 4 * 1024 * 1024) == scope.data,
              try storage.operation!.read(Self.discardName(cleanup.index, kind: "preview.txt"), maximum: 2 * 1024 * 1024) == preview.raw else { throw Self.failure() }
        try scope.requireCurrent(plan, inventory: inventory)
        _ = try append(.discarded, challenge: nil, evidenceSHA256: BackupManifest.digest(receipt.raw + after.raw + inventory.rawFrame),
            attachment: previous.attachment, cleanup: cleanup)
        life.revoke()
    }
    /// A lost deletion acknowledgement is resolved by fresh absence, never by resending its old command.
    func recordInspectedDiscard(scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation,
                                inventory: SNESLibraryInventory, now: Date = Date()) throws {
        let previous = try state(); try scope.validateSources()
        guard [.discardIntent, .discardUncertain].contains(previous.phase), previous.cleanup?.kind == "discard",
              scope.syncReviewSHA256 == plan.reviewSHA256, preview.scopeSHA256 == scope.reviewSHA256, preview.allGone,
              preview.contextSHA256 == inventory.contextSHA256,
              (0...60).contains(now.timeIntervalSince(preview.measuredAt)), (0...60).contains(now.timeIntervalSince(inventory.capacity.measuredAt)),
              scope.retiredObjects.allSatisfy({ inventory.capacity.objects[$0] == nil }),
              !inventory.menus.contains(where: { $0.id == scope.retiredMenuID }),
              !scope.retireNamespace || (!inventory.capacity.namespaceReady && !inventory.incompleteNamespace) else { throw Self.failure() }
        try scope.requireCurrent(plan, inventory: inventory)
        _ = try append(.discarded, challenge: nil, evidenceSHA256: BackupManifest.digest(scope.data + preview.raw + inventory.rawFrame),
            attachment: previous.attachment, cleanup: previous.cleanup)
        life.revoke()
    }
    static func discardName(_ index: Int, kind: String) -> String { String(format: "discard-%04d-", index) + kind }
    static func cleanupName(_ index: Int, kind: String) -> String { String(format: "cleanup-%04d-", index) + kind }
    func currentBackup() throws -> SNESLibrarySnapshotReference? { try state().backupReference }
    func cancelUnstarted() throws {
        guard try state().phase == .prepared else { throw Self.failure() }
        life.revoke(); _ = try append(.discarded, challenge: nil)
    }
    /// Delete only this terminal operation's app-owned prepared cache. User backups are a separate store.
    @discardableResult func purgePreparedMaterial() throws -> Bool {
        let state = try state()
        guard [.finished, .discarded].contains(state.phase) else { throw Self.failure() }
        try plan.backup.validate()
        if state.phase == .finished {
            guard let reference = state.backupReference else { throw Self.failure() }
            _ = try reference.reopen()
        }
        return try Self.removePreparedMaterial(plan.material, root: operation.deletingLastPathComponent())
    }
    /// No journal or dispatch can reference a package abandoned before preparation completed.
    @discardableResult static func discardUnsentMaterial(_ material: SNESLibraryMaterial, root: URL) throws -> Bool {
        let storage = try RestoreJournalStorage(root: root); defer { try? storage.closeLease() }
        let names = try storage.root.names().filter { $0.hasPrefix(prefix) }
        guard names.count <= 256 else { throw failure() }
        for name in names {
            let folder = try RestoreDirectory(storage.root.url.appendingPathComponent(name)), raw = try folder.read("plan.json", maximum: 24 * 1024 * 1024)
            let identity = try SNESLibrarySyncPlan.identity(data: raw)
            _ = try load(folder, review: BackupManifest.digest(raw))
            guard name == prefix + identity.id.uuidString, identity.id != material.menu.id else { throw failure() }
        }
        return try removePreparedMaterial(material, root: storage.root.url)
    }
    /// Cache cleanup happens before the terminal lease is released, including when the view drops its journal afterward.
    func closeCompleted() throws -> String? {
        guard [.finished, .discarded].contains(try state().phase) else { throw Self.failure() }
        var issue: String?
        do { try purgePreparedMaterial() }
        catch { issue = "Your console change is complete and Mac backups are kept. Some temporary preparation files could not be cleared from the Mac." }
        life.revoke(); try storage.closeLease(); return issue
    }
    private static func removePreparedMaterial(_ material: SNESLibraryMaterial, root: URL) throws -> Bool {
        let parent = try RestoreDirectory(root.appendingPathComponent("Prepared"))
        let leaf = "SNES-Library-" + material.menu.id.uuidString
        guard material.directory.path == parent.url.appendingPathComponent(leaf).standardizedFileURL.path else { throw Self.failure() }
        var info = stat()
        if fstatat(parent.fd, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Self.failure() }; return false
        }
        let folder = try RestoreDirectory(material.directory)
        for directory in [parent, folder] {
            var value = stat()
            guard fstat(directory.fd, &value) == 0, value.st_uid == getuid(), value.st_mode & 0o777 == 0o700 else { throw Self.failure() }
        }
        try material.validate(sourcePolicy: .frozenRecovery)
        let names = try folder.names()
        var identities: [String: SNESLibrarySourceFile.Identity] = [:]
        for name in names {
            var value = stat()
            guard fstatat(folder.fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0, value.st_mode & S_IFMT == S_IFREG,
                  value.st_nlink == 1, value.st_uid == getuid(), value.st_mode & 0o777 == 0o600 else { throw Self.failure() }
            identities[name] = .init(value)
        }
        // Hash again after pinning identities, before the first unlink. Never follow or recursively remove unknown entries.
        try material.validate(sourcePolicy: .frozenRecovery)
        guard try folder.names() == names else { throw Self.failure() }
        for name in names {
            try folder.check(); try parent.check()
            let fd = openat(folder.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw Self.failure() }
            let valid: Bool
            do {
                defer { Darwin.close(fd) }
                var held = stat(), named = stat()
                valid = fstat(fd, &held) == 0 && fstatat(folder.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
                    identities[name] == SNESLibrarySourceFile.Identity(held) && identities[name] == SNESLibrarySourceFile.Identity(named) &&
                    held.st_mode & S_IFMT == S_IFREG && held.st_nlink == 1 && held.st_uid == getuid()
                guard valid, unlinkat(folder.fd, name, 0) == 0 else { throw Self.failure() }
            }
        }
        guard try folder.names().isEmpty, fsync(folder.fd) == 0 else { throw Self.failure() }
        try folder.check(); try parent.check()
        guard unlinkat(parent.fd, leaf, AT_REMOVEDIR) == 0, fsync(parent.fd) == 0 else { throw Self.failure() }
        try parent.check(); return true
    }
    func close() throws { life.revoke(); try storage.closeLease() }
    private func state() throws -> State {
        try storage.checkLock()
        guard try storage.operation!.read("plan.json", maximum: 24 * 1024 * 1024) == plan.data else { throw Self.failure() }
        return try Self.load(storage.operation!, review: plan.reviewSHA256)
    }
    private func append(_ phase: Phase, challenge: UUID?, evidenceSHA256: String? = nil, attachment: RecoveryProbeUSBDevice? = nil, backupReference: SNESLibrarySnapshotReference? = nil, cleanup: Cleanup? = nil) throws -> String {
        let previous = try state(); guard previous.count < 128 else { throw Self.failure() }
        let raw = try Self.encode(Record(phase: phase, planSHA256: plan.reviewSHA256, previousSHA256: previous.lastSHA256, challenge: challenge, evidenceSHA256: evidenceSHA256, attachment: attachment, backupReference: backupReference, cleanup: cleanup))
        try storage.write(raw, name: Self.name(previous.count), directory: storage.operation!)
        try storage.sync(storage.operation!); return BackupManifest.digest(raw)
    }
    private static func checkOthers(_ storage: RestoreJournalStorage, excluding: String?, hwid: String) throws {
        let names = try storage.root.names().filter { $0.hasPrefix(prefix) && $0 != excluding }
        guard names.count <= 256 else { throw failure() }
        for name in names {
            let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(name)), raw = try directory.read("plan.json", maximum: 24 * 1024 * 1024)
            let summary = try SNESLibrarySyncPlan.identity(data: raw)
            guard name == prefix + summary.id.uuidString else { throw failure() }
            let state = try load(directory, review: BackupManifest.digest(raw))
            if summary.hwid == hwid && !([.discarded, .finished].contains(state.phase)) { throw failure() }
        }
    }
    private static func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(record)
    }
    private static func load(_ directory: RestoreDirectory, review: String) throws -> State {
        let names = try directory.names(), numbered = names.filter { $0.count == 9 && $0.hasSuffix(".json") && $0.prefix(4).allSatisfy(\.isNumber) }
        guard numbered.count >= 1, numbered.count <= 128,
              Set(numbered) == Set((0..<numbered.count).map(Self.name)) else { throw failure() }
        var allowed = Set(["plan.json"] + numbered)
        var previous: Record?, last: String?
        for index in 0..<numbered.count {
            let raw = try directory.read(name(index), maximum: 65536), value = try JSONDecoder().decode(Record.self, from: raw)
            guard raw == (try encode(value)), value.planSHA256 == review, value.previousSHA256 == last,
                  ([.copied, .awaitingRestart, .awaitingTest, .accepted, .finished, .rollbackIntent, .rollbackAwaitingRestart, .rolledBack].contains(value.phase) || (value.phase == .discarded && value.cleanup?.kind == "discard")) ? value.evidenceSHA256.map(SNESDataSnapshotChunk.isDigest) == true : value.evidenceSHA256 == nil else { throw failure() }
            if [.selectionIntent, .selectionUncertain, .awaitingRestart, .awaitingTest, .accepted, .cleanupIntent, .cleanupUncertain, .discardIntent, .discardUncertain, .finished, .rollbackIntent, .rollbackUncertain, .rollbackAwaitingRestart, .rolledBack].contains(value.phase) || (value.phase == .discarded && value.cleanup?.kind == "discard") {
                guard let attachment = value.attachment, [UInt16(0x6a06), UInt16(0x6a07), UInt16(0x6a0b)].contains(attachment.deviceVersion) else { throw failure() }
                _ = try SNESStartupTrialUSBPolicy.nativeIdentity(attachment)
            } else { guard value.attachment == nil else { throw failure() } }
            if [.accepted, .cleanupIntent, .cleanupUncertain, .finished].contains(value.phase) {
                guard let reference = value.backupReference else { throw failure() }; try reference.validateMetadata()
                if value.phase == .accepted { guard value.evidenceSHA256 == BackupManifest.digest(try SNESLibraryMenu.encode(reference)) else { throw failure() } }
            } else { guard value.backupReference == nil else { throw failure() } }
            if [.cleanupIntent, .cleanupUncertain, .discardIntent, .discardUncertain].contains(value.phase) || ([.finished, .discarded].contains(value.phase) && value.cleanup != nil) {
                guard let cleanup = value.cleanup, [cleanup.scopeSHA256, cleanup.previewSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest),
                      cleanup.index > 0, cleanup.index <= index else { throw failure() }
                let discard = [.discardIntent, .discardUncertain, .discarded].contains(value.phase)
                guard discard ? cleanup.kind == "discard" : cleanup.kind == nil else { throw failure() }
                if [.cleanupIntent, .discardIntent].contains(value.phase) { guard cleanup.index == index else { throw failure() } }
                allowed.insert(discard ? discardName(cleanup.index, kind: "scope.json") : cleanupName(cleanup.index, kind: "scope.json"))
                allowed.insert(discard ? discardName(cleanup.index, kind: "preview.txt") : cleanupName(cleanup.index, kind: "preview.txt"))
            } else { guard value.cleanup == nil else { throw failure() } }
            if let previous {
                let valid = ([.copyIntent, .copyUncertain, .copied, .selectionIntent, .selectionUncertain, .discardUncertain, .rolledBack].contains(previous.phase) && value.phase == .discardIntent && value.challenge != nil)
                    || (previous.phase == .discardUncertain && value.phase == .discarded && value.challenge == nil && value.cleanup == previous.cleanup && value.attachment == previous.attachment)
                    || (previous.phase == .discardIntent && [.discardUncertain, .discarded].contains(value.phase) && value.challenge == nil && value.cleanup == previous.cleanup && value.attachment == previous.attachment)
                    || (previous.phase == .prepared && value.phase == .copyIntent && value.challenge != nil)
                    || (previous.phase == .copyIntent && value.phase == .copyUncertain && value.challenge == nil)
                    || ([.copyIntent, .copyUncertain, .selectionIntent, .selectionUncertain].contains(previous.phase) && value.phase == .copied && value.challenge == nil)
                    || (previous.phase == .prepared && value.phase == .discarded && value.challenge == nil)
                    || (previous.phase == .copied && value.phase == .selectionIntent && value.challenge != nil)
                    || (previous.phase == .selectionIntent && [.selectionUncertain, .awaitingRestart].contains(value.phase) && value.challenge == nil && value.attachment == previous.attachment)
                    || ([.selectionIntent, .selectionUncertain, .awaitingRestart, .awaitingTest].contains(previous.phase) && value.phase == .awaitingTest && value.challenge == nil && value.attachment?.registryEntryID != previous.attachment?.registryEntryID)
                    || ([.awaitingTest, .accepted, .cleanupUncertain].contains(previous.phase) && value.phase == .accepted && value.challenge == nil && value.attachment == previous.attachment)
                    || ([.accepted, .cleanupUncertain].contains(previous.phase) && value.phase == .cleanupIntent && value.challenge != nil && value.attachment == previous.attachment && value.backupReference == previous.backupReference)
                    || ([.accepted, .cleanupUncertain].contains(previous.phase) && value.phase == .finished && value.challenge == nil && value.cleanup == previous.cleanup && value.attachment == previous.attachment && value.backupReference == previous.backupReference)
                    || (previous.phase == .cleanupIntent && [.cleanupUncertain, .finished].contains(value.phase) && value.challenge == nil && value.cleanup == previous.cleanup && value.attachment == previous.attachment && value.backupReference == previous.backupReference)
                    || ([.selectionUncertain,.awaitingRestart,.awaitingTest,.rollbackUncertain].contains(previous.phase) && value.phase == .rollbackIntent && value.challenge != nil)
                    || (previous.phase == .rollbackIntent && [.rollbackUncertain,.rollbackAwaitingRestart].contains(value.phase) && value.challenge == nil && value.attachment == previous.attachment)
                    || ([.rollbackIntent,.rollbackUncertain,.rollbackAwaitingRestart].contains(previous.phase) && value.phase == .rolledBack && value.challenge == nil && value.attachment?.registryEntryID != previous.attachment?.registryEntryID)
                guard valid else { throw failure() }
            } else { guard value.phase == .prepared, value.challenge == nil else { throw failure() } }
            previous = value; last = BackupManifest.digest(raw)
        }
        guard Set(names).isSubset(of: allowed), names.contains("plan.json"), let previous, let last else { throw failure() }
        return State(phase: previous.phase, count: numbered.count, lastSHA256: last, challenge: previous.challenge, attachment: previous.attachment, backupReference: previous.backupReference, cleanup: previous.cleanup)
    }
}
