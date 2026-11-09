import Foundation
import Darwin
import SwiftHakchiCore

enum SNESReplacementSaveJournalPolicy {
    static func requireOperation(_ url: URL) throws {
        let prefix = "SNESSaveTransfer-"
        guard url.isFileURL, url == url.standardizedFileURL,
              url.deletingLastPathComponent().path == (try SNESLibraryJournalPolicy.root()).path,
              url.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))),
              url.lastPathComponent == prefix + id.uuidString else { throw SNESLibraryInventory.failure() }
    }
}

/// A permit is revoked as soon as its owning journal closes or becomes uncertain.
private final class SNESReplacementSavePermitLife: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true, dispatched = false
    func require() throws { lock.lock(); defer { lock.unlock() }; guard active else { throw SNESLibraryInventory.failure() } }
    func claim() throws { lock.lock(); defer { lock.unlock() }; guard active, !dispatched else { throw SNESLibraryInventory.failure() }; dispatched = true }
    func revoke() { lock.lock(); active = false; lock.unlock() }
}

/// Durable intent and read-only recovery records. A scoped, one-use staging
/// permit never replaces the native session's live checks or user approval.
actor SNESReplacementSaveJournal {
    enum Phase: String, Codable, Sendable { case prepared, writeIntent, uncertain, publicationIntent, publicationUncertain, publicationVerified, completed, cancelled }
    struct Prepared: Sendable { let operation: URL, reviewSHA256: String }
    struct Pending: Sendable { let operation: URL, reviewSHA256: String, phase: Phase, stage: StageIntent? }
    struct PublicationSummary: Sendable {
        let gameCode: String, saveDescription: String
        let fileCount: Int, byteCount: Int64, existingProfile: Bool
    }
    struct StagingOption: Identifiable, Sendable {
        let group: Int, summary: PublicationSummary
        var id: Int { group }
    }
    /// Durable description of exactly one reviewed stage. It is not a permit.
    struct StageIntent: Codable, Equatable, Sendable {
        let group: Int, stageID: UUID, challenge: UUID
        let contextSHA256: String, stateSHA256: String, runtimeSHA256: String, scriptSHA256: String, inputSHA256: String
    }
    struct PublicationIntent: Codable, Equatable, Sendable {
        let group: Int, stageID: UUID, challenge: UUID
        let contextSHA256: String, stateSHA256: String, runtimeSHA256: String
        let switcherSHA256: String, scriptSHA256: String, receiptSHA256: String
    }
    struct StagePermit: Sendable {
        let operation: URL, intent: StageIntent
        private let planSHA256: String, review: SNESReplacementSaveEnvelope, life: SNESReplacementSavePermitLife
        fileprivate init(operation: URL, intent: StageIntent, planSHA256: String, review: SNESReplacementSaveEnvelope, life: SNESReplacementSavePermitLife) {
            self.operation = operation; self.intent = intent; self.planSHA256 = planSHA256; self.review = review; self.life = life
        }
        func require(request: SNESReplacementSaveStageCommands.Request, before: SNESLibraryInventory) throws {
            try life.require(); try review.validate()
            let directory = try RestoreDirectory(operation)
            let current = try SNESReplacementSaveJournal.load(directory, expectedSHA256: planSHA256)
            guard current.phase == .writeIntent, current.stage == intent, current.plan.hwid == before.hwid, current.plan.reviewSHA256 == review.sha256,
                  before.contextSHA256 == intent.contextSHA256, before.stateSHA256 == intent.stateSHA256,
                  intent.scriptSHA256 == BackupManifest.digest(Data(request.script.utf8)),
                  intent.inputSHA256 == BackupManifest.digest(request.input) else { throw SNESLibraryInventory.failure() }
            try review.validate(); try life.require()
        }
        func claimDispatch(request: SNESReplacementSaveStageCommands.Request, before: SNESLibraryInventory) throws {
            try require(request: request, before: before); try life.claim()
            try require(request: request, before: before)
        }
        func requireOwner(_ context: SNESLibraryContext) throws {
            try life.require(); try SNESReplacementSaveJournalPolicy.requireOperation(operation)
            try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
            guard context.supportsLibrarySync, context.sha256 == intent.contextSHA256,
                  context.installation.expected.runtimeSHA256 == intent.runtimeSHA256,
                  context.installation.expected.hwid == review.plan.destinationInventory.hwid,
                  context.installation.catalogContentSHA256 == review.plan.destinationInventory.catalogSHA256 else { throw SNESLibraryInventory.failure() }
            try review.validate(); try life.require()
        }
    }
    /// Single-use authority for the temporary helper only, never saved data.
    struct HelperDeliveryPermit: Sendable {
        let operation: URL
        private let planSHA256: String, review: SNESReplacementSaveEnvelope, stage: StageIntent
        private let contextSHA256: String, scriptSHA256: String, inputSHA256: String, receiptSHA256: String
        private let life: SNESReplacementSavePermitLife
        fileprivate init(operation: URL, planSHA256: String, review: SNESReplacementSaveEnvelope, stage: StageIntent,
                         request: SNESReplacementSaveHelperDelivery.Request, life: SNESReplacementSavePermitLife) {
            self.operation = operation; self.planSHA256 = planSHA256; self.review = review; self.stage = stage
            contextSHA256 = request.contextSHA256; scriptSHA256 = BackupManifest.digest(Data(request.script.utf8))
            inputSHA256 = BackupManifest.digest(request.input); receiptSHA256 = BackupManifest.digest(request.receipt); self.life = life
        }
        func require(request: SNESReplacementSaveHelperDelivery.Request, before: SNESLibraryInventory) throws {
            try life.require(); try review.validate(); try review.plan.requireCurrent(before)
            let current = try SNESReplacementSaveJournal.load(RestoreDirectory(operation), expectedSHA256: planSHA256)
            guard current.phase == .uncertain, current.stage == stage, current.plan.hwid == before.hwid,
                  current.plan.reviewSHA256 == review.sha256, stage.stateSHA256 == before.stateSHA256,
                  before.contextSHA256 == contextSHA256, request.contextSHA256 == contextSHA256,
                  request.hwid == before.hwid, request.runtimeSHA256 == stage.runtimeSHA256,
                  scriptSHA256 == BackupManifest.digest(Data(request.script.utf8)),
                  inputSHA256 == BackupManifest.digest(request.input), receiptSHA256 == BackupManifest.digest(request.receipt) else { throw SNESLibraryInventory.failure() }
            try life.require()
        }
        func claimDispatch(request: SNESReplacementSaveHelperDelivery.Request, before: SNESLibraryInventory) throws {
            try require(request: request, before: before); try life.claim(); try require(request: request, before: before)
        }
        func requireOwner(_ context: SNESLibraryContext) throws {
            try life.require(); try SNESReplacementSaveJournalPolicy.requireOperation(operation)
            try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
            guard context.supportsLibrarySync, context.sha256 == contextSHA256,
                  context.installation.expected.runtimeSHA256 == stage.runtimeSHA256,
                  context.installation.expected.hwid == review.plan.destinationInventory.hwid,
                  context.installation.catalogContentSHA256 == review.plan.destinationInventory.catalogSHA256 else { throw SNESLibraryInventory.failure() }
            try review.validate(); try life.require()
        }
    }
    /// A one-use permit for the exact recorded publication request. The native
    /// session still checks the stage, helper, attachment and user approval.
    struct PublicationPermit: Sendable {
        let operation: URL
        private let planSHA256: String, review: SNESReplacementSaveEnvelope, intent: PublicationIntent
        private let life: SNESReplacementSavePermitLife
        fileprivate init(operation: URL, planSHA256: String, review: SNESReplacementSaveEnvelope, intent: PublicationIntent, life: SNESReplacementSavePermitLife) {
            self.operation = operation; self.planSHA256 = planSHA256; self.review = review; self.intent = intent; self.life = life
        }
        func require(request: SNESReplacementSaveProfilePublication.Request, before: SNESLibraryInventory) throws {
            try life.require(); try review.validate(); try review.plan.requireCurrent(before)
            let current = try SNESReplacementSaveJournal.load(RestoreDirectory(operation), expectedSHA256: planSHA256)
            guard current.phase == .publicationIntent, current.publication == intent,
                  current.plan.hwid == before.hwid, current.plan.reviewSHA256 == review.sha256,
                  before.contextSHA256 == intent.contextSHA256, before.stateSHA256 == intent.stateSHA256,
                  request.challenge == intent.challenge, intent.scriptSHA256 == BackupManifest.digest(Data(request.script.utf8)),
                  intent.receiptSHA256 == BackupManifest.digest(request.receipt) else { throw SNESLibraryInventory.failure() }
            try life.require()
        }
        func claimDispatch(request: SNESReplacementSaveProfilePublication.Request, before: SNESLibraryInventory) throws {
            try require(request: request, before: before); try life.claim(); try require(request: request, before: before)
        }
        func requireOwner(_ context: SNESLibraryContext) throws {
            try life.require(); try SNESReplacementSaveJournalPolicy.requireOperation(operation)
            try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
            guard context.supportsLibrarySync, context.sha256 == intent.contextSHA256,
                  context.installation.expected.runtimeSHA256 == intent.runtimeSHA256,
                  context.installation.expected.hwid == review.plan.destinationInventory.hwid,
                  context.installation.catalogContentSHA256 == review.plan.destinationInventory.catalogSHA256 else { throw SNESLibraryInventory.failure() }
            try review.validate(); try life.require()
        }
    }
    private struct Plan: Codable {
        let version: Int, scope: String, id: UUID, hwid: String, reviewSHA256: String
        let source: SNESLibrarySnapshotReference, destination: SNESLibrarySnapshotReference
    }
    private struct Completion: Codable {
        let backup: SNESLibrarySnapshotReference, stateSHA256: String, contextSHA256: String
    }
    private struct Record: Codable {
        let phase: Phase, planSHA256: String, previousSHA256: String?, stage: StageIntent?, publication: PublicationIntent?
        let completion: Completion?, verification: Completion?
        init(phase: Phase, planSHA256: String, previousSHA256: String?, stage: StageIntent? = nil, publication: PublicationIntent? = nil, completion: Completion? = nil, verification: Completion? = nil) {
            self.phase = phase; self.planSHA256 = planSHA256; self.previousSHA256 = previousSHA256; self.stage = stage; self.publication = publication
            self.completion = completion; self.verification = verification
        }
    }
    private struct State { let plan: Plan, phase: Phase, count: Int, lastSHA256: String, stage: StageIntent?, publication: PublicationIntent?, verification: Completion? }
    private static let prefix = "SNESSaveTransfer-", draftPrefix = "SNESSaveDraft-"
    private let storage: RestoreJournalStorage, review: SNESReplacementSaveEnvelope, planSHA256: String
    private var permitLife: SNESReplacementSavePermitLife?

    static func prepare(review: SNESReplacementSaveEnvelope, root: URL) throws -> Prepared {
        try Task.checkCancellation(); try review.validate()
        let hwid = review.plan.destinationInventory.hwid
        guard hwid.count == 32, SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }) else { throw SNESLibraryInventory.failure() }
        let storage = try SNESLibraryJournal.firmwareLease(hwid: hwid, root: root)
        defer { try? storage.closeLease() }
        let draft = try createUnpublished(review: review, storage: storage)
        let staged = try RestoreDirectory(draft.operation)
        let state = try load(staged, expectedSHA256: draft.reviewSHA256, unpublished: true)
        try Task.checkCancellation(); try review.plan.validate(); try storage.checkLock(); try staged.check()
        let name = prefix + state.plan.id.uuidString
        guard renameatx_np(storage.root.fd, staged.url.lastPathComponent, storage.root.fd, name, UInt32(RENAME_EXCL)) == 0 else { throw RestoreDirectory.failure() }
        try storage.sync(storage.root)
        let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
        _ = try load(directory, expectedSHA256: draft.reviewSHA256)
        try storage.closeLease()
        return .init(operation: directory.url, reviewSHA256: draft.reviewSHA256)
    }

    /// Prepare a private, inactive draft under the existing lease. Until its
    /// atomic publication, a crash cannot leave an incomplete active journal.
    static func createUnpublished(review: SNESReplacementSaveEnvelope, storage: RestoreJournalStorage) throws -> Prepared {
        try Task.checkCancellation(); try storage.checkLock(); try review.validate()
        let identity = try SNESReplacementSaveEnvelope.identity(data: review.data, expectedSHA256: review.sha256)
        let hwid = review.plan.destinationInventory.hwid
        guard hwid.count == 32, SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }) else { throw SNESLibraryInventory.failure() }
        let id = UUID(), name = draftPrefix + id.uuidString
        guard mkdirat(storage.root.fd, name, 0o700) == 0 else { throw RestoreDirectory.failure() }
        let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
        guard fchmod(directory.fd, 0o700) == 0 else { throw RestoreDirectory.failure() }
        let plan = Plan(version: 1, scope: "snes-replacement-save-transaction", id: id, hwid: hwid,
                        reviewSHA256: review.sha256, source: identity.source, destination: identity.destination)
        let raw = try encode(plan), digest = BackupManifest.digest(raw)
        try storage.write(raw, name: "plan.json", directory: directory)
        try storage.write(review.data, name: "review.json", directory: directory)
        try storage.write(encode(Record(phase: .prepared, planSHA256: digest, previousSHA256: nil)), name: eventName(0), directory: directory)
        try storage.sync(directory); try storage.sync(storage.root); try review.plan.validate()
        _ = try load(directory, expectedSHA256: digest, unpublished: true)
        return .init(operation: directory.url, reviewSHA256: digest)
    }

    init(operation: URL, reviewSHA256: String, originals: SNESOriginalGamesFrame) throws {
        let storage = try RestoreJournalStorage(root: operation.deletingLastPathComponent(), operation: operation)
        let state = try Self.load(storage.operation!, expectedSHA256: reviewSHA256)
        try SNESLibraryJournal.requireNoPendingForSave(storage: storage, hwid: state.plan.hwid, excludingSave: operation.lastPathComponent)
        let raw = try storage.operation!.read("review.json", maximum: 4 * 1024 * 1024)
        let review = try SNESReplacementSaveEnvelope.load(data: raw, expectedSHA256: state.plan.reviewSHA256, originals: originals)
        guard review.plan.destinationInventory.hwid == state.plan.hwid else { throw SNESLibraryInventory.failure() }
        self.storage = storage; self.review = review; self.planSHA256 = reviewSHA256
    }

    deinit { permitLife?.revoke() }
    func close() throws { permitLife?.revoke(); try storage.closeLease() }
    func phase() throws -> Phase { try state().phase }

    /// Live inspection must use the app's fixed journal root and this console's
    /// checked installation. This does not authorize a write or clear recovery.
    func requireNativeInspection(context: SNESLibraryContext) throws {
        let current = try state()
        try SNESReplacementSaveJournalPolicy.requireOperation(storage.operation!.url)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard (current.phase == .writeIntent || current.phase == .uncertain), current.stage != nil, context.supportsLibrarySync,
              current.plan.hwid == context.installation.expected.hwid,
              review.plan.destinationInventory.catalogSHA256 == context.installation.catalogContentSHA256 else { throw SNESLibraryInventory.failure() }
        try review.validate()
    }

    /// Check the current connection for read-only publication recovery. A
    /// reconnect has a new session ID; hardware, installation, and the
    /// recorded runtime must still match the original review.
    func requireNativePublicationInspection(context: SNESLibraryContext) throws {
        let current = try state()
        try SNESReplacementSaveJournalPolicy.requireOperation(storage.operation!.url)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard [.publicationIntent, .publicationUncertain, .publicationVerified].contains(current.phase),
              let stage = current.stage, let publication = current.publication,
              context.supportsLibrarySync,
              current.plan.hwid == context.installation.expected.hwid,
              review.plan.destinationInventory.catalogSHA256 == context.installation.catalogContentSHA256,
              stage.runtimeSHA256 == context.installation.expected.runtimeSHA256,
              publication.runtimeSHA256 == context.installation.expected.runtimeSHA256 else { throw SNESLibraryInventory.failure() }
        try review.validate()
    }

    func requireNativePreparation(context: SNESLibraryContext) throws {
        let current = try state()
        try SNESReplacementSaveJournalPolicy.requireOperation(storage.operation!.url)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard current.phase == .prepared, current.stage == nil, context.supportsLibrarySync,
              current.plan.hwid == context.installation.expected.hwid,
              review.plan.destinationInventory.catalogSHA256 == context.installation.catalogContentSHA256 else { throw SNESLibraryInventory.failure() }
        try review.validate()
    }

    /// Read one complete group from the pinned backups. This neither contacts
    /// the console nor authorizes a transfer or a retry after uncertainty.
    func preparePayload(group: Int, challenge: UUID) throws -> SNESReplacementSavePayload {
        let prior = try state()
        guard prior.phase == .prepared || prior.phase == .writeIntent else { throw SNESLibraryInventory.failure() }
        if let stage = prior.stage { guard stage.group == group, stage.challenge == challenge else { throw SNESLibraryInventory.failure() } }
        let payload = try SNESReplacementSavePayload.prepare(review: review, group: group, challenge: challenge)
        let after = try state()
        guard after.phase == prior.phase, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        return payload
    }

    /// Prepare all complete new sets for one reviewed game while the journal
    /// is still unsent. No console-write or retry permission is created.
    func prepareGamePayload(gameCode: String, challenge: UUID) throws -> SNESReplacementSavePayload {
        let prior = try state()
        guard prior.phase == .prepared, prior.stage == nil else { throw SNESLibraryInventory.failure() }
        let payload = try SNESReplacementSavePayload.prepareGame(review: review, gameCode: gameCode, challenge: challenge)
        let after = try state()
        guard after.phase == prior.phase, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        return payload
    }

    /// Derive a stable stage name from the durable operation and group. This
    /// prepares a command only; it does not grant permission to dispatch it.
    func prepareStage(group: Int, before: SNESLibraryInventory, runtimeSHA256: String, challenge: UUID) throws -> SNESReplacementSaveStageCommands.Request {
        let prior = try state()
        guard (prior.phase == .prepared || prior.phase == .writeIntent), (0...4095).contains(group) else { throw SNESLibraryInventory.failure() }
        if let stage = prior.stage {
            guard stage.group == group, stage.challenge == challenge, stage.runtimeSHA256 == runtimeSHA256,
                  stage.contextSHA256 == before.contextSHA256, stage.stateSHA256 == before.stateSHA256 else { throw SNESLibraryInventory.failure() }
        }
        let stageID = try Self.stageID(operation: prior.plan.id, group: group)
        let request = try SNESReplacementSaveStageCommands.prepare(review: review, group: group, before: before,
            runtimeSHA256: runtimeSHA256, challenge: challenge, stageID: stageID)
        if let stage = prior.stage {
            guard stage.stageID == stageID, stage.scriptSHA256 == BackupManifest.digest(Data(request.script.utf8)),
                  stage.inputSHA256 == BackupManifest.digest(request.input) else { throw SNESLibraryInventory.failure() }
        }
        let after = try state()
        guard after.phase == prior.phase, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        return request
    }

    /// Prepare a read-only check of the same stage after a possible interruption.
    /// The result cannot clear the journal or authorize another write.
    func prepareStageInspection(group: Int, before: SNESLibraryInventory, runtimeSHA256: String, challenge: UUID) throws -> SNESReplacementSaveStageInspection.Request {
        let prior = try state()
        guard (prior.phase == .writeIntent || prior.phase == .uncertain), let stage = prior.stage,
              stage.group == group, stage.runtimeSHA256 == runtimeSHA256,
              stage.stateSHA256 == before.stateSHA256 else { throw SNESLibraryInventory.failure() }
        let stageID = try Self.stageID(operation: prior.plan.id, group: group)
        let request = try SNESReplacementSaveStageInspection.prepare(review: review, group: group, before: before,
            runtimeSHA256: runtimeSHA256, challenge: challenge, stageID: stageID, stagedChallenge: stage.challenge)
        let after = try state()
        guard after.phase == prior.phase, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        return request
    }

    /// Plain-language information for a preview; this does not inspect the
    /// console or create permission to publish.
    func publicationSummary(group: Int) throws -> PublicationSummary {
        let prior = try state(), groups = try review.plan.protectedGroups()
        guard [.uncertain, .publicationVerified].contains(prior.phase), prior.stage?.group == group, groups.indices.contains(group) else { throw SNESLibraryInventory.failure() }
        let result = try Self.summary(review: review, selected: groups[group])
        let after = try state()
        guard after.phase == prior.phase, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        return result
    }

    /// List only complete sets this version can stage and later publish. This
    /// is a Mac-side review, not a permit or a console operation.
    static func stagingOptions(review: SNESReplacementSaveEnvelope, before: SNESLibraryInventory, runtimeSHA256: String) throws -> [StagingOption] {
        guard SNESDataSnapshotChunk.isDigest(runtimeSHA256) else { throw SNESLibraryInventory.failure() }
        _ = try SNESReplacementSaveHelper.bundled()
        try review.validate(); try review.plan.requireCurrent(before)
        let groups = try review.plan.protectedGroups()
        var result: [StagingOption] = []
        for (group, selected) in groups.enumerated() {
            do {
                _ = try SNESReplacementSaveProfilePublication.prepare(review: review, group: group, before: before,
                    runtimeSHA256: runtimeSHA256, switcherSHA256: SNESReplacementSaveHelper.sha256,
                    challenge: UUID(), stageID: UUID(), stagedChallenge: UUID())
                result.append(.init(group: group, summary: try summary(review: review, selected: selected)))
            } catch {
                // A currently unsupported layout is not made actionable. A
                // changed review or destination remains an error, not a skip.
                try review.validate(); try review.plan.requireCurrent(before)
            }
        }
        try review.validate(); try review.plan.requireCurrent(before)
        return result
    }

    private static func summary(review: SNESReplacementSaveEnvelope, selected: SNESNativeSaveLayout.Group) throws -> PublicationSummary {
        let paths = Set(selected.paths)
        let entries = review.plan.files.filter { paths.contains($0.path) }
        guard entries.count == paths.count, !entries.isEmpty else { throw SNESLibraryInventory.failure() }
        var size: Int64 = 0
        for entry in entries {
            let (next, overflow) = size.addingReportingOverflow(Int64(entry.byteCount))
            guard !overflow else { throw SNESLibraryInventory.failure() }; size = next
        }
        let description: String
        switch selected.kind {
        case .cartridge: description = "Game save"
        case .systemSave: description = "Game settings save"
        case .suspendPoint(let slot): description = "Suspend point \(slot)"
        }
        let profile = "clover/profiles/0/" + selected.gameCode
        let existing = review.plan.destinationInventory.directories.contains { $0.path == profile }
        try review.validate()
        return .init(gameCode: selected.gameCode, saveDescription: description, fileCount: entries.count, byteCount: size, existingProfile: existing)
    }

    /// Authorize one temporary-helper delivery. The native session must also
    /// verify the staged files, live connection and explicit preview approval.
    func authorizeHelperDelivery(request: SNESReplacementSaveHelperDelivery.Request, before: SNESLibraryInventory, approved: Bool) throws -> HelperDeliveryPermit {
        guard approved else { throw SNESLibraryInventory.failure() }
        let prior = try state()
        guard prior.phase == .uncertain, let stage = prior.stage, stage.stateSHA256 == before.stateSHA256,
              stage.runtimeSHA256 == request.runtimeSHA256, before.contextSHA256 == request.contextSHA256,
              before.hwid == request.hwid else { throw SNESLibraryInventory.failure() }
        try review.plan.requireCurrent(before)
        let expected = try SNESReplacementSaveHelperDelivery.prepare(helper: SNESReplacementSaveHelper.bundled(), hwid: before.hwid,
            contextSHA256: before.contextSHA256, runtimeSHA256: stage.runtimeSHA256, selection: before.selection, challenge: request.challenge)
        guard expected.script == request.script, expected.input == request.input, expected.receipt == request.receipt else { throw SNESLibraryInventory.failure() }
        let after = try state()
        guard after.phase == prior.phase, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        permitLife?.revoke()
        let life = SNESReplacementSavePermitLife(); permitLife = life
        return .init(operation: storage.operation!.url, planSHA256: planSHA256, review: review, stage: stage, request: request, life: life)
    }

    func revokeHelperDelivery() { permitLife?.revoke(); permitLife = nil }

    /// Preparing this request does not prove that the stage exists and does
    /// not grant permission to send it.
    func prepareProfilePublication(group: Int, before: SNESLibraryInventory, runtimeSHA256: String, switcherSHA256: String, challenge: UUID) throws -> SNESReplacementSaveProfilePublication.Request {
        let prior = try state()
        guard [.uncertain, .publicationIntent, .publicationUncertain].contains(prior.phase), let stage = prior.stage, stage.group == group,
              stage.runtimeSHA256 == runtimeSHA256,
              stage.stateSHA256 == before.stateSHA256, stage.stageID == (try Self.stageID(operation: prior.plan.id, group: group)) else {
            throw SNESLibraryInventory.failure()
        }
        if let recorded = prior.publication {
            guard recorded.group == group, recorded.stageID == stage.stageID, recorded.challenge == challenge,
                  recorded.contextSHA256 == before.contextSHA256, recorded.stateSHA256 == before.stateSHA256,
                  recorded.runtimeSHA256 == runtimeSHA256, recorded.switcherSHA256 == switcherSHA256 else { throw SNESLibraryInventory.failure() }
        }
        // Rebuild the staged request from the durable intent. A record made
        // with different command or payload bytes cannot authorize a preview.
        do {
            let stageInventory = try Self.recordedInventory(review.plan.destinationInventory, contextSHA256: stage.contextSHA256)
            let staged = try SNESReplacementSaveStageCommands.prepare(review: review, group: group, before: stageInventory,
                runtimeSHA256: runtimeSHA256, challenge: stage.challenge, stageID: stage.stageID)
            guard stage.scriptSHA256 == BackupManifest.digest(Data(staged.script.utf8)),
                  stage.inputSHA256 == BackupManifest.digest(staged.input) else { throw SNESLibraryInventory.failure() }
        }
        let request = try SNESReplacementSaveProfilePublication.prepare(review: review, group: group, before: before,
            runtimeSHA256: runtimeSHA256, switcherSHA256: switcherSHA256, challenge: challenge, stageID: stage.stageID, stagedChallenge: stage.challenge)
        if let recorded = prior.publication {
            guard recorded.scriptSHA256 == BackupManifest.digest(Data(request.script.utf8)),
                  recorded.receiptSHA256 == BackupManifest.digest(request.receipt) else { throw SNESLibraryInventory.failure() }
        }
        let after = try state()
        guard after.phase == prior.phase, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        return request
    }

    /// Records intent only; it does not authorize or dispatch a console write.
    func recordProfilePublicationIntent(group: Int, before: SNESLibraryInventory, runtimeSHA256: String, switcherSHA256: String, challenge: UUID, approved: Bool) throws {
        guard approved else { throw SNESLibraryInventory.failure() }
        let prior = try state()
        guard prior.phase == .uncertain, let stage = prior.stage, prior.publication == nil else { throw SNESLibraryInventory.failure() }
        let request = try prepareProfilePublication(group: group, before: before, runtimeSHA256: runtimeSHA256, switcherSHA256: switcherSHA256, challenge: challenge)
        let publication = PublicationIntent(group: group, stageID: stage.stageID, challenge: challenge,
            contextSHA256: before.contextSHA256, stateSHA256: before.stateSHA256, runtimeSHA256: runtimeSHA256,
            switcherSHA256: switcherSHA256, scriptSHA256: BackupManifest.digest(Data(request.script.utf8)), receiptSHA256: BackupManifest.digest(request.receipt))
        let after = try state()
        guard after.phase == prior.phase, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        try append(.publicationIntent, publication: publication)
    }

    /// Record the exact approved operation before issuing a one-use permit.
    func authorizeProfilePublication(request: SNESReplacementSaveProfilePublication.Request, group: Int, before: SNESLibraryInventory,
                                     runtimeSHA256: String, challenge: UUID, approved: Bool) throws -> PublicationPermit {
        guard approved, request.challenge == challenge else { throw SNESLibraryInventory.failure() }
        let expected = try prepareProfilePublication(group: group, before: before, runtimeSHA256: runtimeSHA256,
            switcherSHA256: SNESReplacementSaveHelper.sha256, challenge: challenge)
        guard expected.script == request.script, expected.receipt == request.receipt else { throw SNESLibraryInventory.failure() }
        try recordProfilePublicationIntent(group: group, before: before, runtimeSHA256: runtimeSHA256,
            switcherSHA256: SNESReplacementSaveHelper.sha256, challenge: challenge, approved: true)
        let current = try state()
        guard current.phase == .publicationIntent, let intent = current.publication else { throw SNESLibraryInventory.failure() }
        permitLife?.revoke()
        let life = SNESReplacementSavePermitLife(); permitLife = life
        return .init(operation: storage.operation!.url, planSHA256: planSHA256, review: review, intent: intent, life: life)
    }

    func markProfilePublicationUncertain() throws { permitLife?.revoke(); try append(.publicationUncertain) }

    /// Offline inventory comparison only; it grants no recovery or write permit.
    func inspectProfilePublication(observed: SNESLibraryInventory) throws -> SNESReplacementSaveProfileRecovery.Outcome {
        let prior = try state()
        guard (prior.phase == .publicationIntent || prior.phase == .publicationUncertain), let intended = prior.publication else {
            throw SNESLibraryInventory.failure()
        }
        let recorded = try Self.recordedInventory(review.plan.destinationInventory, contextSHA256: intended.contextSHA256)
        _ = try prepareProfilePublication(group: intended.group, before: recorded,
            runtimeSHA256: intended.runtimeSHA256, switcherSHA256: intended.switcherSHA256, challenge: intended.challenge)
        let outcome = try SNESReplacementSaveProfileRecovery.inspect(review: review, group: intended.group, observed: observed)
        let after = try state()
        guard after.phase == prior.phase, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        return outcome
    }

    /// Preserve an exact post-copy backup before asking anyone to play. This
    /// writes only a Mac record and does not authorize a console change.
    func recordVerifiedPublication(backup: SNESLibraryBackup, observed: SNESLibraryInventory) throws {
        let prior = try state()
        guard prior.phase == .publicationUncertain, prior.publication != nil,
              backup.directory != prior.plan.source.directory, backup.directory != prior.plan.destination.directory,
              try inspectProfilePublication(observed: observed) == .published else { throw SNESLibraryInventory.failure() }
        let verified = try checkedBackup(backup, observed: observed, prior: prior)
        let proof = Completion(backup: try SNESLibrarySnapshotReference(verified), stateSHA256: observed.stateSHA256,
                               contextSHA256: observed.contextSHA256)
        try appendProtectedEvent(.publicationVerified, prior: prior, backup: verified, verification: proof)
    }

    /// Reopen the protected post-copy backup before comparing a later game
    /// session. The result is informational and is not a write permit.
    func inspectAfterGameTest(observed: SNESLibraryInventory) throws -> [String] {
        let prior = try state()
        guard prior.phase == .publicationVerified, let publication = prior.publication, let proof = prior.verification else { throw SNESLibraryInventory.failure() }
        let original = try proof.backup.reopen()
        guard original.inventory.stateSHA256 == proof.stateSHA256, original.inventory.contextSHA256 == proof.contextSHA256 else { throw SNESLibraryInventory.failure() }
        let changes = try SNESReplacementSaveProfileRecovery.changesAfterGameTest(review: review, group: publication.group,
            published: original.inventory, observed: observed)
        try original.validate()
        let current = try state()
        guard current.phase == prior.phase, current.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        return changes
    }

    private func checkedBackup(_ backup: SNESLibraryBackup, observed: SNESLibraryInventory, prior: State) throws -> SNESLibraryBackup {
        try backup.validate()
        let verified = try SNESLibraryBackup.open(directory: backup.directory)
        guard verified.manifestSHA256 == backup.manifestSHA256, verified.inventory.hwid == prior.plan.hwid,
              verified.inventory.catalogSHA256 == observed.catalogSHA256,
              verified.inventory.contextSHA256 == observed.contextSHA256,
              verified.inventory.snapshotSHA256 == observed.snapshotSHA256,
              verified.inventory.stateSHA256 == observed.stateSHA256 else { throw SNESLibraryInventory.failure() }
        try verified.validate(); try backup.validate(); return verified
    }

    /// After explicit game testing, back up the resulting data and complete
    /// only if changes are confined to the tested game and no files vanished.
    func finishVerifiedPublication(backup: SNESLibraryBackup, observed: SNESLibraryInventory, confirmed: Bool) throws {
        guard confirmed else { throw SNESLibraryInventory.failure() }
        let prior = try state()
        guard [.publicationUncertain, .publicationVerified].contains(prior.phase), let publication = prior.publication,
              backup.directory != prior.plan.source.directory, backup.directory != prior.plan.destination.directory else { throw SNESLibraryInventory.failure() }
        let verified = try checkedBackup(backup, observed: observed, prior: prior)
        if prior.phase == .publicationVerified {
            guard let proof = prior.verification, backup.directory != proof.backup.directory else { throw SNESLibraryInventory.failure() }
            let original = try proof.backup.reopen()
            guard original.inventory.stateSHA256 == proof.stateSHA256, original.inventory.contextSHA256 == proof.contextSHA256 else { throw SNESLibraryInventory.failure() }
            _ = try SNESReplacementSaveProfileRecovery.changesAfterGameTest(review: review, group: publication.group,
                published: original.inventory, observed: observed)
            try original.validate()
        } else {
            // Existing records can finish only if the exact publication still matches.
            guard try inspectProfilePublication(observed: observed) == .published else { throw SNESLibraryInventory.failure() }
        }
        let completion = Completion(backup: try SNESLibrarySnapshotReference(verified), stateSHA256: observed.stateSHA256,
                                    contextSHA256: observed.contextSHA256)
        try appendProtectedEvent(.completed, prior: prior, backup: verified, completion: completion)
    }

    /// Publish complete records atomically. An interrupted private draft leaves
    /// the previous recovery record readable and both backups untouched.
    private func appendProtectedEvent(_ phase: Phase, prior: State, backup: SNESLibraryBackup,
                                      completion: Completion? = nil, verification: Completion? = nil) throws {
        guard Self.permits(prior.phase, phase),
              (phase == .completed) == (completion != nil),
              (phase == .publicationVerified) == (verification != nil) else { throw SNESLibraryInventory.failure() }
        try Task.checkCancellation(); try storage.checkLock()
        let raw = try Self.encode(Record(phase: phase, planSHA256: planSHA256, previousSHA256: prior.lastSHA256,
                                         completion: completion, verification: verification))
        let draft = ".snes-save-completion-" + prior.plan.id.uuidString + "-" + UUID().uuidString
        try storage.write(raw, name: draft, directory: storage.root)
        try storage.sync(storage.root)
        try Task.checkCancellation(); try storage.checkLock(); try backup.validate(); try review.plan.validate()
        let current = try state()
        guard current.phase == prior.phase, current.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        if let proof = prior.verification { let original = try proof.backup.reopen(); try original.validate() }
        guard renameatx_np(storage.root.fd, draft, storage.operation!.fd, Self.eventName(prior.count), UInt32(RENAME_EXCL)) == 0 else { throw SNESLibraryInventory.failure() }
        try storage.sync(storage.operation!); try storage.sync(storage.root)
        guard try state().phase == phase else { throw SNESLibraryInventory.failure() }
    }

    /// Reconstruct the inert inventory used by a durable command. This does
    /// not attest a live console or refresh the inventory's measurement time.
    private static func recordedInventory(_ original: SNESLibraryInventory, contextSHA256: String) throws -> SNESLibraryInventory {
        guard SNESDataSnapshotChunk.isDigest(contextSHA256), original.excludedMenuID == nil,
              let first = original.rawFrame.firstIndex(of: 10),
              let second = original.rawFrame[original.rawFrame.index(after: first)...].firstIndex(of: 10) else { throw SNESLibraryInventory.failure() }
        let start = original.rawFrame.index(after: first)
        guard original.rawFrame[start..<second] == Data(("CONTEXT " + original.contextSHA256).utf8) else { throw SNESLibraryInventory.failure() }
        var raw = original.rawFrame
        raw.replaceSubrange(start..<second, with: Data(("CONTEXT " + contextSHA256).utf8))
        let result = try SNESLibraryInventory(raw: raw, challenge: original.challenge, contextSHA256: contextSHA256,
            hwid: original.hwid, catalogSHA256: original.catalogSHA256, measuredAt: original.capacity.measuredAt)
        guard result.stateSHA256 == original.stateSHA256, result.snapshotSHA256 == original.snapshotSHA256 else { throw SNESLibraryInventory.failure() }
        return result
    }

    private static func stageID(operation: UUID, group: Int) throws -> UUID {
        guard (0...4095).contains(group) else { throw SNESLibraryInventory.failure() }
        let digest = Array(BackupManifest.digest(Data("snes-save-stage-v1 \(operation.uuidString) \(group)".utf8)).prefix(32))
        let text = String(digest[0..<8]) + "-" + String(digest[8..<12]) + "-" + String(digest[12..<16]) + "-" + String(digest[16..<20]) + "-" + String(digest[20..<32])
        guard let id = UUID(uuidString: text) else { throw SNESLibraryInventory.failure() }
        return id
    }

    /// Records intent only. It does not grant a permit or dispatch a command.
    func recordWriteIntent(approved: Bool) throws {
        guard approved else { throw SNESLibraryInventory.failure() }
        try review.plan.validate(); _ = try review.plan.protectedGroups()
        try append(.writeIntent)
    }

    /// Persist a specific stage before dispatch. The returned one-use permit
    /// covers inactive staging only and still requires the native live checks.
    @discardableResult func recordStageIntent(group: Int, before: SNESLibraryInventory, runtimeSHA256: String, challenge: UUID, approved: Bool) throws -> StagePermit {
        guard approved else { throw SNESLibraryInventory.failure() }
        let prior = try state()
        guard prior.phase == .prepared else { throw SNESLibraryInventory.failure() }
        let request = try prepareStage(group: group, before: before, runtimeSHA256: runtimeSHA256, challenge: challenge)
        let stage = StageIntent(group: group, stageID: try Self.stageID(operation: prior.plan.id, group: group), challenge: challenge,
            contextSHA256: before.contextSHA256, stateSHA256: before.stateSHA256, runtimeSHA256: runtimeSHA256,
            scriptSHA256: BackupManifest.digest(Data(request.script.utf8)), inputSHA256: BackupManifest.digest(request.input))
        let after = try state()
        guard after.phase == .prepared, after.lastSHA256 == prior.lastSHA256 else { throw SNESLibraryInventory.failure() }
        try append(.writeIntent, stage: stage)
        let life = SNESReplacementSavePermitLife(); permitLife = life
        return StagePermit(operation: storage.operation!.url, intent: stage, planSHA256: planSHA256, review: review, life: life)
    }

    func recordedStage() throws -> StageIntent? { try state().stage }
    func markUncertain() throws { permitLife?.revoke(); try append(.uncertain) }
    /// An interrupted staging attempt stays unresolved. This records no claim
    /// about console files and grants no permission to retry or publish them.
    func markInterruptedStageForReview() throws {
        let current = try state()
        guard current.phase == .writeIntent, current.stage != nil else { throw SNESLibraryInventory.failure() }
        try markUncertain()
    }
    func cancelUnsent() throws { try append(.cancelled) }

    /// Compares a supplied inventory; it neither attests a live console nor
    /// clears this journal or authorizes another write.
    func inspect(observed: SNESLibraryInventory) throws -> SNESReplacementSaveRecovery {
        let current = try state()
        guard current.phase == .writeIntent || current.phase == .uncertain else { throw SNESLibraryInventory.failure() }
        // A stage permit can only write to the private staging directory, not
        // to game profiles. Do not attribute any live change to that intent,
        // even when the changed bytes happen to match a reviewed save.
        if current.stage != nil { try review.plan.requireCurrent(observed) }
        let result = try SNESReplacementSaveRecovery.inspect(plan: review.plan, observed: observed)
        let after = try state()
        guard after.phase == current.phase, after.lastSHA256 == current.lastSHA256 else { throw SNESLibraryInventory.failure() }
        return result
    }

    /// Locate an unfinished record without issuing a permit or contacting USB.
    static func pending(root: URL, hwid: String) throws -> Pending? {
        guard hwid.count == 32, SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }) else { throw SNESLibraryInventory.failure() }
        let storage = try RestoreJournalStorage(root: root); defer { try? storage.closeLease() }
        var result: Pending?
        for name in try names(storage) {
            let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
            let raw = try directory.read("plan.json", maximum: 65536), digest = BackupManifest.digest(raw)
            let state = try load(directory, expectedSHA256: digest)
            if state.plan.hwid == hwid && ![.cancelled, .completed].contains(state.phase) {
                guard result == nil else { throw SNESLibraryInventory.failure() }
                result = .init(operation: directory.url, reviewSHA256: digest, phase: state.phase, stage: state.stage)
            }
        }
        return result
    }

    /// A prepared record has never dispatched a write. It can be closed even
    /// if the referenced backups have since been moved or are unavailable.
    static func closeUnsentReview(operation: URL, reviewSHA256: String) throws {
        let storage = try RestoreJournalStorage(root: operation.deletingLastPathComponent(), operation: operation)
        defer { try? storage.closeLease() }
        let directory = storage.operation!, prior = try load(directory, expectedSHA256: reviewSHA256)
        guard prior.phase == .prepared else { throw SNESLibraryInventory.failure() }
        let raw = try encode(Record(phase: .cancelled, planSHA256: reviewSHA256, previousSHA256: prior.lastSHA256))
        try storage.write(raw, name: eventName(prior.count), directory: directory)
        try storage.sync(directory); try storage.sync(storage.root)
        guard try load(directory, expectedSHA256: reviewSHA256).phase == .cancelled else { throw SNESLibraryInventory.failure() }
    }

    private func state() throws -> State {
        try storage.checkLock()
        let current = try Self.load(storage.operation!, expectedSHA256: planSHA256)
        try SNESLibraryJournal.requireNoPendingForSave(storage: storage, hwid: current.plan.hwid, excludingSave: storage.operation!.url.lastPathComponent)
        return current
    }
    private func append(_ phase: Phase, stage: StageIntent? = nil, publication: PublicationIntent? = nil) throws {
        try Task.checkCancellation(); let prior = try state()
        guard phase != .completed, phase != .publicationVerified, Self.permits(prior.phase, phase), stage == nil || phase == .writeIntent,
              (publication != nil) == (phase == .publicationIntent) else { throw SNESLibraryInventory.failure() }
        let raw = try Self.encode(Record(phase: phase, planSHA256: planSHA256, previousSHA256: prior.lastSHA256, stage: stage, publication: publication))
        try storage.write(raw, name: Self.eventName(prior.count), directory: storage.operation!)
        try storage.sync(storage.operation!); try storage.sync(storage.root)
        guard try state().phase == phase else { throw SNESLibraryInventory.failure() }
    }

    static func requireNoPending(storage: RestoreJournalStorage, hwid: String, excluding: String? = nil) throws {
        for name in try names(storage) where name != excluding {
            let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
            let raw = try directory.read("plan.json", maximum: 65536), state = try load(directory, expectedSHA256: BackupManifest.digest(raw))
            if state.plan.hwid == hwid && ![.cancelled, .completed].contains(state.phase) { throw SNESLibraryJournal.failure() }
        }
    }
    static func requireBackupsNotInUse(storage: RestoreJournalStorage, directory: URL) throws {
        for name in try names(storage) {
            let operation = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
            let raw = try operation.read("plan.json", maximum: 65536), state = try load(operation, expectedSHA256: BackupManifest.digest(raw))
            if ![.cancelled, .completed].contains(state.phase) && ([state.plan.source.directory.path, state.plan.destination.directory.path] + (state.verification.map { [$0.backup.directory.path] } ?? [])).contains(directory.standardizedFileURL.path) {
                throw RecoveryProbeError.refused("This backup is needed to inspect an unfinished saved-game transfer. Keep it until the transfer is resolved.")
            }
        }
    }
    private static func names(_ storage: RestoreJournalStorage) throws -> [String] {
        try storage.checkLock(); let values = try storage.root.names().filter { $0.hasPrefix(prefix) }
        guard values.count <= 256 else { throw SNESLibraryInventory.failure() }; return values
    }
    private static func eventName(_ index: Int) -> String { String(format: "%04d.json", index) }
    private static func permits(_ old: Phase, _ next: Phase) -> Bool {
        (old == .prepared && (next == .writeIntent || next == .cancelled)) || (old == .writeIntent && next == .uncertain) ||
        (old == .uncertain && next == .publicationIntent) || (old == .publicationIntent && next == .publicationUncertain) ||
        (old == .publicationUncertain && (next == .completed || next == .publicationVerified)) ||
        (old == .publicationVerified && next == .completed)
    }
    private static func load(_ directory: RestoreDirectory, expectedSHA256: String, unpublished: Bool = false) throws -> State {
        var info = stat()
        guard fstat(directory.fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw SNESLibraryInventory.failure() }
        try requirePrivateFile("plan.json", in: directory); try requirePrivateFile("review.json", in: directory)
        let planData = try directory.read("plan.json", maximum: 65536)
        guard SNESDataSnapshotChunk.isDigest(expectedSHA256), BackupManifest.digest(planData) == expectedSHA256 else { throw SNESLibraryInventory.failure() }
        let plan = try JSONDecoder().decode(Plan.self, from: planData)
        guard try encode(plan) == planData, plan.version == 1, plan.scope == "snes-replacement-save-transaction",
              directory.url.lastPathComponent == (unpublished ? draftPrefix : prefix) + plan.id.uuidString, plan.hwid.count == 32,
              SNESRuntimeBinding.hex(plan.hwid), plan.hwid.contains(where: { $0 != "0" }) else { throw SNESLibraryInventory.failure() }
        try plan.source.validateMetadata(); try plan.destination.validateMetadata()
        let reviewData = try directory.read("review.json", maximum: 4 * 1024 * 1024)
        let identity = try SNESReplacementSaveEnvelope.identity(data: reviewData, expectedSHA256: plan.reviewSHA256)
        guard identity.source == plan.source, identity.destination == plan.destination else { throw SNESLibraryInventory.failure() }
        let names = try directory.names(), events = names.filter { $0 != "plan.json" && $0 != "review.json" }
        guard !events.isEmpty, events.count <= 7 else { throw SNESLibraryInventory.failure() }
        var previous: String?, phase: Phase?, stage: StageIntent?, publication: PublicationIntent?, verification: Completion?
        for (index, name) in events.enumerated() {
            guard name == eventName(index) else { throw SNESLibraryInventory.failure() }
            try requirePrivateFile(name, in: directory)
            let raw = try directory.read(name, maximum: 65536), record = try JSONDecoder().decode(Record.self, from: raw)
            guard try encode(record) == raw, record.planSHA256 == expectedSHA256, record.previousSHA256 == previous,
                  phase.map({ permits($0, record.phase) }) ?? (record.phase == .prepared) else { throw SNESLibraryInventory.failure() }
            if record.phase == .writeIntent {
                if let intent = record.stage {
                    guard (0...4095).contains(intent.group), intent.stageID == (try stageID(operation: plan.id, group: intent.group)),
                          [intent.contextSHA256, intent.stateSHA256, intent.runtimeSHA256, intent.scriptSHA256, intent.inputSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest) else { throw SNESLibraryInventory.failure() }
                }
                stage = record.stage
            } else if record.stage != nil { throw SNESLibraryInventory.failure() }
            if record.phase == .publicationIntent {
                guard let intended = record.publication, let staged = stage, intended.group == staged.group, intended.stageID == staged.stageID,
                      intended.stateSHA256 == staged.stateSHA256,
                      intended.runtimeSHA256 == staged.runtimeSHA256,
                      [intended.contextSHA256, intended.switcherSHA256, intended.scriptSHA256, intended.receiptSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest) else { throw SNESLibraryInventory.failure() }
                publication = intended
            } else if record.publication != nil { throw SNESLibraryInventory.failure() }
            if record.phase == .publicationVerified {
                guard let proof = record.verification, publication != nil,
                      SNESDataSnapshotChunk.isDigest(proof.stateSHA256), SNESDataSnapshotChunk.isDigest(proof.contextSHA256),
                      proof.backup.directory != plan.source.directory, proof.backup.directory != plan.destination.directory else { throw SNESLibraryInventory.failure() }
                try proof.backup.validateMetadata(); verification = proof
            } else if record.verification != nil { throw SNESLibraryInventory.failure() }
            if record.phase == .completed {
                guard let finished = record.completion, publication != nil,
                      SNESDataSnapshotChunk.isDigest(finished.stateSHA256), SNESDataSnapshotChunk.isDigest(finished.contextSHA256),
                      finished.backup.directory != plan.source.directory, finished.backup.directory != plan.destination.directory,
                      verification.map({ $0.backup.directory != finished.backup.directory }) ?? true else { throw SNESLibraryInventory.failure() }
                try finished.backup.validateMetadata()
            } else if record.completion != nil { throw SNESLibraryInventory.failure() }
            phase = record.phase; previous = BackupManifest.digest(raw)
        }
        guard let phase, let previous else { throw SNESLibraryInventory.failure() }
        return .init(plan: plan, phase: phase, count: events.count, lastSHA256: previous, stage: stage, publication: publication, verification: verification)
    }
    private static func requirePrivateFile(_ name: String, in directory: RestoreDirectory) throws {
        try directory.check(); var info = stat()
        guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600 else { throw SNESLibraryInventory.failure() }
        try directory.check()
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
}
