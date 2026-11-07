import Foundation
import SwiftHakchiCore

protocol SNESLibraryConnectionIO: Sendable {
    func open() async throws
    func inventory() async throws -> [RecoveryProbeUSBDevice]
    func identity(challenge: UUID) async throws -> Data
    func compatibilitySupport(context: SNESLibraryContext, challenge: UUID) async throws -> Data
    func compatibilityInstalledSupport(context: SNESLibraryContext, helperSHA256: String) async throws -> Data
    func compatibilityPreflight(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data
    func compatibilityManagerInventory(context: SNESLibraryContext, game: Game, source: SNESLibraryROMSource, helperSHA256: String) async throws -> SNESCompatibilityManagerInventory.Observation
    func compatibilityRecovery(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data
    func compatibilityRecoveryCurrent(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, region: SNESRecoveryRegion) async throws -> Data
    func compatibilityRetainedState(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, paired: Bool) async throws -> Data
    func compatibilityRetainedImage(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, paired: Bool) async throws -> Data
    func compatibilityRetiredImage(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, paired: Bool) async throws -> Data
    func compatibilityRetainedTime(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data
    func compatibilityStateArchive(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data
    func inspectClockRecovery(context: SNESLibraryContext, plan: SNESClockRecoveryPlan, helperSHA256: String) async throws -> Data
    func inspectBatteryRecovery(context: SNESLibraryContext, plan: SNESBatteryRecoveryPlan, helperSHA256: String) async throws -> Data
    func frontendSupport(context: SNESLibraryContext, challenge: UUID) async throws -> Data
    func resetInput(context: SNESLibraryContext, challenge: UUID) async throws -> Data
    func powerInput(context: SNESLibraryContext, challenge: UUID) async throws -> Data
    func report(installation: SNESLibraryInstallation, challenge: UUID) async throws -> Data
    func libraryInventory(context: SNESLibraryContext, challenge: UUID) async throws -> Data
    func inspectReplacementSaveStage(context: SNESLibraryContext, request: SNESReplacementSaveStageInspection.Request) async throws -> SNESReplacementSaveStageInspectionReceipt.Outcome
    func stageReplacementSave(context: SNESLibraryContext, request: SNESReplacementSaveStageCommands.Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.StagePermit) async throws -> SNESReplacementSaveStageReceipt
    func deliverReplacementSaveHelper(context: SNESLibraryContext, request: SNESReplacementSaveHelperDelivery.Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.HelperDeliveryPermit) async throws
    func publishReplacementSave(context: SNESLibraryContext, request: SNESReplacementSaveProfilePublication.Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.PublicationPermit) async throws
    func recoveryInventory(context: SNESLibraryContext, permit: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> Data
    func librarySpace(context: SNESLibraryContext, selection: SNESLibraryInventory.Selection, challenge: UUID) async throws -> Data
    func libraryChunk(context: SNESLibraryContext, file: SNESLibraryInventory.File, offset: Int, challenge: UUID) async throws -> Data
    func copyLibrary(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, permit: SNESLibraryCopyPermit, before: SNESLibraryInventory) async throws -> Data
    func restoreLibrarySelection(context:SNESLibraryContext,plan:SNESLibrarySyncPlan,permit:SNESLibraryRollbackPermit,before:SNESLibraryInventory) async throws->Data
    func rollbackPendingAbsent(context:SNESLibraryContext,plan:SNESLibrarySyncPlan,challenge:UUID) async throws->Data
    func saveLibrarySelection(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, permit: SNESLibrarySelectionPermit, before: SNESLibraryInventory) async throws -> Data
    func cleanupPreview(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan,
                        reconciliation: SNESLibraryReconciliationPermit?, challenge: UUID) async throws -> Data
    func removeLibraryTemporary(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan,
                                preview: SNESLibraryCleanupObservation, permit: SNESLibraryCleanupPermit) async throws -> Data
    func discardUpload(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, reconciliation: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> Data
    func discardPreview(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, reconciliation: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> Data
    func discardLibraryCopy(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation, permit: SNESLibraryDiscardPermit) async throws -> Data
    func disconnect() async
}
extension SNESLibraryConnectionIO {
    func inspectReplacementSaveStage(context: SNESLibraryContext, request: SNESReplacementSaveStageInspection.Request) async throws -> SNESReplacementSaveStageInspectionReceipt.Outcome { throw SNESLibraryInventory.failure() }
    func stageReplacementSave(context: SNESLibraryContext, request: SNESReplacementSaveStageCommands.Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.StagePermit) async throws -> SNESReplacementSaveStageReceipt { throw SNESLibraryInventory.failure() }
    func deliverReplacementSaveHelper(context: SNESLibraryContext, request: SNESReplacementSaveHelperDelivery.Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.HelperDeliveryPermit) async throws { throw SNESLibraryInventory.failure() }
    func publishReplacementSave(context: SNESLibraryContext, request: SNESReplacementSaveProfilePublication.Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.PublicationPermit) async throws { throw SNESLibraryInventory.failure() }
    func compatibilityStateArchive(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func compatibilityRetainedTime(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func compatibilityRetainedImage(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, paired: Bool) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func compatibilityRetiredImage(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, paired: Bool) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func compatibilityRetainedState(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, paired: Bool) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func compatibilityManagerInventory(context: SNESLibraryContext, game: Game, source: SNESLibraryROMSource, helperSHA256: String) async throws -> SNESCompatibilityManagerInventory.Observation { throw SNESCompatibilitySupportFrame.failure() }
    func inspectClockRecovery(context: SNESLibraryContext, plan: SNESClockRecoveryPlan, helperSHA256: String) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func inspectBatteryRecovery(context: SNESLibraryContext, plan: SNESBatteryRecoveryPlan, helperSHA256: String) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func compatibilityRecoveryCurrent(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, region: SNESRecoveryRegion) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func compatibilityRecovery(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func compatibilityInstalledSupport(context: SNESLibraryContext, helperSHA256: String) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func compatibilityPreflight(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data { throw SNESCompatibilitySupportFrame.failure() }
    func resetInput(context: SNESLibraryContext, challenge: UUID) async throws -> Data {throw SNESCompatibilitySupportFrame.failure()}
    func powerInput(context: SNESLibraryContext, challenge: UUID) async throws -> Data {throw SNESCompatibilitySupportFrame.failure()}
    func frontendSupport(context: SNESLibraryContext, challenge: UUID) async throws -> Data {throw SNESCompatibilitySupportFrame.failure()}
    func compatibilitySupport(context: SNESLibraryContext, challenge: UUID) async throws -> Data {throw SNESCompatibilitySupportFrame.failure()}
    func restoreLibrarySelection(context:SNESLibraryContext,plan:SNESLibrarySyncPlan,permit:SNESLibraryRollbackPermit,before:SNESLibraryInventory) async throws->Data {throw SNESLibraryInventory.failure()}
    func rollbackPendingAbsent(context:SNESLibraryContext,plan:SNESLibrarySyncPlan,challenge:UUID) async throws->Data {throw SNESLibraryInventory.failure()}

    func discardUpload(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, reconciliation: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> Data { throw SNESLibraryInventory.failure() }
    func discardPreview(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, reconciliation: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> Data { throw SNESLibraryInventory.failure() }
    func discardLibraryCopy(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation, permit: SNESLibraryDiscardPermit) async throws -> Data { throw SNESLibraryInventory.failure() }

    func removeLibraryTemporary(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan,
                                preview: SNESLibraryCleanupObservation, permit: SNESLibraryCleanupPermit) async throws -> Data { throw SNESLibraryInventory.failure() }

    func cleanupPreview(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan,
                        reconciliation: SNESLibraryReconciliationPermit?, challenge: UUID) async throws -> Data { throw SNESLibraryInventory.failure() }
    func saveLibrarySelection(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, permit: SNESLibrarySelectionPermit, before: SNESLibraryInventory) async throws -> Data {
        throw SNESLibraryInventory.failure()
    }
    func copyLibrary(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, permit: SNESLibraryCopyPermit, before: SNESLibraryInventory) async throws -> Data {
        throw SNESLibraryInventory.failure()
    }
    func recoveryInventory(context: SNESLibraryContext, permit: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> Data {
        throw SNESLibraryInventory.failure()
    }
}
struct SNESLibraryOwnerRecords: Sendable {
    let installation: SNESLibraryInstallation, index: SNESLibraryInstallationIndex.Loaded
}

/// A checked, read-only preparation. This is not a console-write permit.
struct SNESReplacementSavePublicationPreview: Sendable {
    let request: SNESReplacementSaveProfilePublication.Request
    let helperDelivery: SNESReplacementSaveHelperDelivery.Request
    let helper: SNESReplacementSaveHelper
    let inventory: SNESLibraryInventory
    let summary: SNESReplacementSaveJournal.PublicationSummary
    let group: Int
}

/// Read-only observation from a checked attachment. This never grants copy, switch or deletion permission.
struct SNESLibraryObservation: Sendable {
    let context: SNESLibraryContext, inventory: SNESLibraryInventory, capacity: SNESLibraryCapacity.Inventory
    let inventoryChallenge: UUID, spaceChallenge: UUID
    let rawSpace: Data, reports: [Data], reportChallenges: [UUID]
    let reconciliationPermit: SNESLibraryReconciliationPermit?
    fileprivate init(context: SNESLibraryContext, inventory: SNESLibraryInventory, capacity: SNESLibraryCapacity.Inventory,
                     inventoryChallenge: UUID, spaceChallenge: UUID, rawSpace: Data, reports: [Data], reportChallenges: [UUID], reconciliationPermit: SNESLibraryReconciliationPermit?) {
        self.context = context; self.inventory = inventory; self.capacity = capacity
        self.inventoryChallenge = inventoryChallenge; self.spaceChallenge = spaceChallenge
        self.rawSpace = rawSpace; self.reports = reports; self.reportChallenges = reportChallenges
        self.reconciliationPermit = reconciliationPermit
    }
}

/// Owns the native context; copy permission additionally requires its durable journal and fresh device checks.
actor SNESLibraryConnectionSession: SNESLibraryCopyDevice, SNESLibrarySelectionDevice, SNESLibraryCleanupDevice, SNESLibraryDiscardDevice, SNESLibraryRollbackDevice {
    typealias LoadOwner = @Sendable (String, UInt16) async throws -> SNESLibraryOwnerRecords
    let attachment: RecoveryProbeUSBDevice
    private let io: any SNESLibraryConnectionIO
    private var operationStamp = UUID()
    private var busy = false {
        didSet { if busy && !oldValue { operationStamp = UUID() } }
    }
    private var closed = true, connected = false
    private var generation = 0
    private var context: SNESLibraryContext?
    private var backingUp = false
    init(attachment: RecoveryProbeUSBDevice, io: any SNESLibraryConnectionIO) { self.attachment = attachment; self.io = io }
    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation, busy else { throw LegacyInspectionError.disconnected }
    }
    private func checkAttachment(_ token: Int) async throws {
        try check(token)
        let devices = try await io.inventory()
        try check(token)
        guard devices == [attachment] else { throw LegacyInspectionError.disconnected }
    }
    func connect(sessionID: UUID, progress: ConsoleConnectionProgressSink = { _ in }, loadOwner: LoadOwner) async throws -> SNESLibraryContext {
        guard !busy, !connected else { throw LegacyInspectionError.busy }
        guard ConsoleAttachmentPolicy.kind(of: attachment) == .nativeSNES else { throw SNESLibraryInstallation.failure() }
        _ = try SNESStartupTrialUSBPolicy.nativeIdentity(attachment)
        busy = true; defer { busy = false }
        generation += 1; let token = generation
        do {
            try await checkAttachment(token)
            closed = false
            await progress(.openingUSB); try check(token)
            try await io.open(); try check(token); try await checkAttachment(token)
            await progress(.identifyingConsole); try check(token)
            let nonce = UUID(), raw = try await io.identity(challenge: nonce)
            try check(token); try await checkAttachment(token)
            let identity = try SNESLibraryIdentity(raw, challenge: nonce)
            await progress(.checkingSetupFiles); try check(token)
            let owner = try await loadOwner(identity.hwid, attachment.deviceVersion)
            try check(token); try await checkAttachment(token)
            guard owner.installation.expected.hwid == identity.hwid,
                  owner.installation.expected.deviceVersion == attachment.deviceVersion else { throw SNESLibraryInstallation.failure() }
            try owner.installation.validate(); try owner.index.validate()
            await progress(.verifyingConsole); try check(token)
            var reports: [Data] = [], challenges: [UUID] = []
            for _ in 0..<2 {
                try await checkAttachment(token); try owner.installation.validate(); try owner.index.validate()
                let challenge = UUID(), report = try await io.report(installation: owner.installation, challenge: challenge)
                try check(token); try await checkAttachment(token); try owner.installation.validate(); try owner.index.validate()
                challenges.append(challenge); reports.append(report)
            }
            let value = try SNESLibraryContext.verify(installation: owner.installation, index: owner.index, attachment: attachment,
                sessionID: sessionID, challenges: challenges, reports: reports)
            try check(token); context = value; connected = true
            return value
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    func observe(_ value: SNESLibraryContext, reconciliation: SNESLibraryReconciliationPermit? = nil) async throws -> SNESLibraryObservation {
        try await requireCurrent(value)
        guard !busy else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        return try await observeLocked(value, reconciliation: reconciliation, token: generation)
    }
    /// Inspect one interrupted save stage without modifying it or clearing its
    /// recovery record. Both surrounding observations must remain unchanged.
    func inspectReplacementSaveStage(journal: SNESReplacementSaveJournal, group: Int) async throws -> SNESReplacementSaveStageInspectionReceipt.Outcome {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try await journal.requireNativeInspection(context: value)
        try await requireCurrent(value)
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            guard connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.disconnected }
        }
        do {
            let before = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token); try await journal.requireNativeInspection(context: value)
            let challenge = UUID()
            let request = try await journal.prepareStageInspection(group: group, before: before.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: challenge)
            try validate(); try request.require(value); try request.requireInventory(before.inventory); try await checkAttachment(token)
            let outcome = try await io.inspectReplacementSaveStage(context: value, request: request)
            try validate(); try await checkAttachment(token)
            let after = try await observeLocked(value, token: token)
            try validate(); try request.requireInventory(after.inventory); try await checkAttachment(token)
            try await journal.requireNativeInspection(context: value)
            let rechecked = try await journal.prepareStageInspection(group: group, before: after.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: challenge)
            guard rechecked.script == request.script, rechecked.input == request.input,
                  rechecked.absent == request.absent, rechecked.incomplete == request.incomplete,
                  rechecked.verified == request.verified else { throw SNESLibraryInventory.failure() }
            try validate(); return outcome
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Build a publication preview only after a fresh stage inspection. The
    /// returned request and helper cannot themselves authorize a write.
    func previewReplacementSavePublication(journal: SNESReplacementSaveJournal, group: Int) async throws -> SNESReplacementSavePublicationPreview {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try await journal.requireNativeInspection(context: value)
        guard try await journal.phase() == .uncertain else { throw SNESLibraryInventory.failure() }
        try await requireCurrent(value)
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            guard connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.disconnected }
        }
        do {
            let helper = try SNESReplacementSaveHelper.bundled()
            let before = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token); try await journal.requireNativeInspection(context: value)
            let inspection = try await journal.prepareStageInspection(group: group, before: before.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: UUID())
            try inspection.require(value); try inspection.requireInventory(before.inventory)
            guard try await io.inspectReplacementSaveStage(context: value, request: inspection) == .verified else { throw SNESLibraryInventory.failure() }
            try validate(); try await checkAttachment(token)
            let after = try await observeLocked(value, token: token)
            try validate(); try inspection.requireInventory(after.inventory); try await checkAttachment(token)
            try await journal.requireNativeInspection(context: value)
            guard try await journal.phase() == .uncertain else { throw SNESLibraryInventory.failure() }
            let request = try await journal.prepareProfilePublication(group: group, before: after.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, switcherSHA256: SNESReplacementSaveHelper.sha256, challenge: UUID())
            let delivery = try SNESReplacementSaveHelperDelivery.prepare(helper: helper, hwid: after.inventory.hwid,
                contextSHA256: value.sha256, runtimeSHA256: value.installation.expected.runtimeSHA256,
                selection: after.inventory.selection, challenge: UUID())
            let summary = try await journal.publicationSummary(group: group)
            try validate(); try await checkAttachment(token)
            _ = try SNESReplacementSaveHelper.validate(helper.bytes)
            return .init(request: request, helperDelivery: delivery, helper: helper, inventory: after.inventory, summary: summary, group: group)
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Deliver only the reviewed helper into temporary runtime memory. Saved
    /// data publication still needs a separate guarded operation and approval.
    func deliverReplacementSaveHelper(journal: SNESReplacementSaveJournal, preview: SNESReplacementSavePublicationPreview, approved: Bool) async throws {
        guard approved else { throw RecoveryProbeError.refused("Review and approve the temporary helper before continuing.") }
        guard let value = context, value.sha256 == preview.inventory.contextSHA256 else { throw LegacyInspectionError.disconnected }
        let checked = try await previewReplacementSavePublication(journal: journal, group: preview.group)
        guard checked.inventory.stateSHA256 == preview.inventory.stateSHA256,
              checked.inventory.snapshotSHA256 == preview.inventory.snapshotSHA256,
              checked.summary.gameCode == preview.summary.gameCode,
              checked.summary.saveDescription == preview.summary.saveDescription,
              checked.summary.fileCount == preview.summary.fileCount,
              checked.summary.byteCount == preview.summary.byteCount,
              checked.summary.existingProfile == preview.summary.existingProfile,
              checked.helper.bytes == preview.helper.bytes else { throw SNESLibraryInventory.failure() }
        try await requireCurrent(value)
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            guard connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.disconnected }
        }
        do {
            let before = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token)
            guard before.inventory.stateSHA256 == preview.inventory.stateSHA256,
                  before.inventory.snapshotSHA256 == preview.inventory.snapshotSHA256 else { throw SNESLibraryInventory.failure() }
            let permit = try await journal.authorizeHelperDelivery(request: preview.helperDelivery, before: before.inventory, approved: approved)
            try validate(); try permit.requireOwner(value); try await checkAttachment(token)
            try await io.deliverReplacementSaveHelper(context: value, request: preview.helperDelivery, before: before.inventory, permit: permit)
            try validate(); try await checkAttachment(token)
            let after = try await observeLocked(value, token: token)
            try validate(); try permit.require(request: preview.helperDelivery, before: after.inventory); try await checkAttachment(token)
            await journal.revokeHelperDelivery()
        } catch {
            await journal.revokeHelperDelivery()
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Publish the exact reviewed save set once. The recovery record remains
    /// open even after matching observations; gameplay verification is separate.
    func publishReplacementSave(journal: SNESReplacementSaveJournal, preview: SNESReplacementSavePublicationPreview,
                                approved: Bool) async throws -> SNESReplacementSaveProfileRecovery.Outcome {
        guard approved else { throw RecoveryProbeError.refused("Review and approve the saved-game copy before continuing.") }
        guard let value = context, value.sha256 == preview.inventory.contextSHA256 else { throw LegacyInspectionError.disconnected }
        let checked = try await previewReplacementSavePublication(journal: journal, group: preview.group)
        guard checked.inventory.stateSHA256 == preview.inventory.stateSHA256,
              checked.inventory.snapshotSHA256 == preview.inventory.snapshotSHA256,
              checked.summary.gameCode == preview.summary.gameCode,
              checked.summary.saveDescription == preview.summary.saveDescription,
              checked.summary.fileCount == preview.summary.fileCount,
              checked.summary.byteCount == preview.summary.byteCount,
              checked.summary.existingProfile == preview.summary.existingProfile,
              checked.helper.bytes == preview.helper.bytes else { throw SNESLibraryInventory.failure() }
        try await requireCurrent(value)
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            guard connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.disconnected }
        }
        do {
            let before = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token)
            guard before.inventory.stateSHA256 == preview.inventory.stateSHA256,
                  before.inventory.snapshotSHA256 == preview.inventory.snapshotSHA256 else { throw SNESLibraryInventory.failure() }
            let expected = try await journal.prepareProfilePublication(group: preview.group, before: before.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, switcherSHA256: SNESReplacementSaveHelper.sha256,
                challenge: preview.request.challenge)
            guard expected.script == preview.request.script, expected.receipt == preview.request.receipt else { throw SNESLibraryInventory.failure() }
            let permit = try await journal.authorizeProfilePublication(request: preview.request, group: preview.group,
                before: before.inventory, runtimeSHA256: value.installation.expected.runtimeSHA256,
                challenge: preview.request.challenge, approved: approved)
            try validate(); try permit.requireOwner(value); try await checkAttachment(token)
            try await io.publishReplacementSave(context: value, request: preview.request, before: before.inventory, permit: permit)
            try validate(); try await checkAttachment(token)
            try await journal.markProfilePublicationUncertain()
            let first = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token)
            let firstResult = try await journal.inspectProfilePublication(observed: first.inventory)
            let last = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token)
            guard first.inventory.stateSHA256 == last.inventory.stateSHA256,
                  first.inventory.snapshotSHA256 == last.inventory.snapshotSHA256,
                  firstResult == .published,
                  try await journal.inspectProfilePublication(observed: last.inventory) == .published else { throw SNESLibraryInventory.failure() }
            return .published
        } catch {
            // If intent was saved, retain it as uncertain even after cancellation.
            try? await Task.detached { try await journal.markProfilePublicationUncertain() }.value
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Compare the destination twice while the same checked connection remains
    /// active. This inspection neither publishes files nor clears the record.
    func inspectReplacementSavePublication(journal: SNESReplacementSaveJournal) async throws -> SNESReplacementSaveProfileRecovery.Outcome {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try await journal.requireNativePublicationInspection(context: value)
        try await requireCurrent(value)
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            guard connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.disconnected }
        }
        do {
            let before = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token)
            try await journal.requireNativePublicationInspection(context: value)
            let first = try await journal.inspectProfilePublication(observed: before.inventory)
            try validate(); try await checkAttachment(token)
            let after = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token)
            guard before.inventory.stateSHA256 == after.inventory.stateSHA256,
                  before.inventory.snapshotSHA256 == after.inventory.snapshotSHA256 else { throw SNESLibraryInventory.failure() }
            let last = try await journal.inspectProfilePublication(observed: after.inventory)
            try await journal.requireNativePublicationInspection(context: value)
            guard first == last else { throw SNESLibraryInventory.failure() }
            try validate(); try await checkAttachment(token)
            return last
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Verify the copied files and retain their exact post-copy state before
    /// the person starts the game. No console files are changed.
    func verifyReplacementSaveBeforeTesting(journal: SNESReplacementSaveJournal, backupRoot: URL) async throws -> SNESLibrarySnapshotReference {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try await journal.requireNativePublicationInspection(context: value)
        guard try await journal.phase() == .publicationUncertain else { throw SNESLibraryInventory.failure() }
        let before = try await observe(value)
        guard try await journal.inspectProfilePublication(observed: before.inventory) == .published else { throw SNESLibraryInventory.failure() }
        let backup = try await captureBackup(before, root: backupRoot, allowCreation: true, forceNew: true)
        let after = try await observe(value)
        guard before.inventory.stateSHA256 == after.inventory.stateSHA256,
              before.inventory.snapshotSHA256 == after.inventory.snapshotSHA256,
              try await journal.inspectProfilePublication(observed: after.inventory) == .published else { throw SNESLibraryInventory.failure() }
        try await requireCurrent(value); try await journal.requireNativePublicationInspection(context: value)
        let reference = try SNESLibrarySnapshotReference(backup)
        try await journal.recordVerifiedPublication(backup: backup, observed: after.inventory)
        return reference
    }

    /// Capture a fresh Mac backup after the user checks the saved game. The
    /// protected pre-test backup permits only reviewed game-profile changes.
    func finishReplacementSavePublication(journal: SNESReplacementSaveJournal, backupRoot: URL,
                                          confirmed: Bool) async throws -> SNESLibrarySnapshotReference {
        guard confirmed else { throw RecoveryProbeError.refused("Check that the saved game works before finishing.") }
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try await journal.requireNativePublicationInspection(context: value)
        guard try await journal.phase() == .publicationVerified else { throw SNESLibraryInventory.failure() }
        let before = try await observe(value)
        let changes = try await journal.inspectAfterGameTest(observed: before.inventory)
        let backup = try await captureBackup(before, root: backupRoot, allowCreation: true, forceNew: true)
        let after = try await observe(value)
        guard before.inventory.stateSHA256 == after.inventory.stateSHA256,
              before.inventory.snapshotSHA256 == after.inventory.snapshotSHA256,
              try await journal.inspectAfterGameTest(observed: after.inventory) == changes else { throw SNESLibraryInventory.failure() }
        try await requireCurrent(value); try await journal.requireNativePublicationInspection(context: value)
        let reference = try SNESLibrarySnapshotReference(backup)
        try await journal.finishVerifiedPublication(backup: backup, observed: after.inventory, confirmed: confirmed)
        return reference
    }
    /// Stage a single reviewed set only. Even a verified stage remains an
    /// unfinished recovery record; this does not publish saved progress.
    func stageReplacementSave(journal: SNESReplacementSaveJournal, group: Int, approved: Bool) async throws -> SNESReplacementSaveStageInspectionReceipt.Outcome {
        guard approved else { throw RecoveryProbeError.refused("Review and approve the saved-game copy before continuing.") }
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try await journal.requireNativePreparation(context: value)
        try await requireCurrent(value)
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        var intentRecorded = false
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            guard connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.disconnected }
        }
        do {
            let before = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token); try await journal.requireNativePreparation(context: value)
            let challenge = UUID()
            let request = try await journal.prepareStage(group: group, before: before.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: challenge)
            try validate(); try await checkAttachment(token)
            let permit = try await journal.recordStageIntent(group: group, before: before.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: challenge, approved: approved)
            intentRecorded = true
            try validate(); try await checkAttachment(token); try permit.requireOwner(value)
            _ = try await io.stageReplacementSave(context: value, request: request, before: before.inventory, permit: permit)
            try validate(); try await checkAttachment(token)
            let after = try await observeLocked(value, token: token)
            try validate(); try permit.require(request: request, before: after.inventory); try await checkAttachment(token)
            let inspectionChallenge = UUID()
            let inspection = try await journal.prepareStageInspection(group: group, before: after.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: inspectionChallenge)
            try inspection.require(value); try inspection.requireInventory(after.inventory)
            let result = try await io.inspectReplacementSaveStage(context: value, request: inspection)
            guard result == .verified else { throw SNESLibraryInventory.failure() }
            try validate(); try await checkAttachment(token)
            let final = try await observeLocked(value, token: token)
            try validate(); try inspection.requireInventory(final.inventory); try await checkAttachment(token)
            // Keep the journal open for the separately reviewed publication step
            // and recovery even after a successful staging check.
            try await journal.markUncertain()
            try validate(); return result
        } catch {
            if intentRecorded { try? await Task.detached { try await journal.markUncertain() }.value }
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    private func observeLocked(_ value: SNESLibraryContext, reconciliation: SNESLibraryReconciliationPermit? = nil, token: Int) async throws -> SNESLibraryObservation {
        func validate() throws { try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID); try reconciliation?.requireOwner(value) }
        do {
            try validate(); try await checkAttachment(token)
            let firstID = UUID(), firstRaw = try await io.report(installation: value.installation, challenge: firstID)
            try validate(); try await checkAttachment(token)
            let first = try SNESStartupTrialReport(firstRaw, expected: value.installation.expected, challenge: firstID)
            let inventoryID = UUID(), raw: Data
            if let reconciliation { raw = try await io.recoveryInventory(context: value, permit: reconciliation, challenge: inventoryID) }
            else { raw = try await io.libraryInventory(context: value, challenge: inventoryID) }
            try validate(); try await checkAttachment(token)
            let inventory = try SNESLibraryInventory(raw: raw, challenge: inventoryID, contextSHA256: value.sha256,
                hwid: value.installation.expected.hwid, catalogSHA256: value.installation.catalogContentSHA256, excludingIncompleteMenu: reconciliation?.excludedMenuID)
            guard !inventory.incompleteNamespace || reconciliation?.allowsIncompleteNamespace == true else { throw SNESLibraryInventory.failure() }
            let lastID = UUID(), lastRaw = try await io.report(installation: value.installation, challenge: lastID)
            try validate(); try await checkAttachment(token)
            let last = try SNESStartupTrialReport(lastRaw, expected: value.installation.expected, challenge: lastID)
            guard first.mcpPID == last.mcpPID, first.daemonPID == last.daemonPID else { throw SNESLibraryInventory.failure() }
            let spaceID = UUID(), spaceRaw = try await io.librarySpace(context: value, selection: inventory.selection, challenge: spaceID)
            try validate(); try await checkAttachment(token)
            let space = try SNESLibrarySpace(spaceRaw, challenge: spaceID, contextSHA256: value.sha256, hwid: value.installation.expected.hwid)
            return SNESLibraryObservation(context: value, inventory: inventory, capacity: try space.capacity(for: inventory),
                inventoryChallenge: inventoryID, spaceChallenge: spaceID, rawSpace: spaceRaw, reports: [firstRaw, lastRaw], reportChallenges: [firstID, lastID], reconciliationPermit: reconciliation)
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    func copy(plan: SNESLibrarySyncPlan, permit: SNESLibraryCopyPermit) async throws -> SNESLibraryCopyResult {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(value); try permit.require(plan)
        try await requireCurrent(value)
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            try plan.requireOwner(value); try permit.require(plan)
        }
        do {
            let before = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token)
            guard before.inventory.stateSHA256 == plan.before.stateSHA256, before.inventory.contextSHA256 == plan.before.contextSHA256 else { throw SNESLibraryInventory.failure() }
            let capacity = try SNESLibraryCapacity.project(menu: plan.material.menu, inventory: before.capacity, expectedContext: value.sha256)
            guard capacity.canFit else { throw SNESLibraryInventory.failure() }
            let request = try SNESLibraryCopyCommands.prepare(menu: plan.material.menu, before: before.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: permit.challenge)
            try validate(); try await checkAttachment(token)
            let raw = try await io.copyLibrary(context: value, plan: plan, permit: permit, before: before.inventory)
            try validate(); try await checkAttachment(token)
            _ = try SNESLibraryCopyReceipt(raw, request: request)
            let after = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token)
            return try SNESLibraryCopyResult(plan: plan, permit: permit, request: request, raw: raw, after: after.inventory)
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    struct DiscardReview: Sendable { let scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation }
    func discardAttachment(plan: SNESLibrarySyncPlan) async throws -> RecoveryProbeUSBDevice {
        try await selectionAttachment(plan: plan)
    }
    func reviewDiscard(plan: SNESLibrarySyncPlan, reconciliation: SNESLibraryReconciliationPermit) async throws -> DiscardReview {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try plan.requireOwner(value); try reconciliation.requireOwner(value)
        guard reconciliation.id == plan.material.menu.id, reconciliation.reviewSHA256 == plan.reviewSHA256,
              reconciliation.excludedMenuID == plan.material.menu.id else { throw SNESLibraryInventory.failure() }
        let before = try await observe(value, reconciliation: reconciliation)
        guard !busy, !backingUp, connected, !closed else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        func validate() throws {
            try check(token); try plan.requireOwner(value); try reconciliation.requireOwner(value)
            guard connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.disconnected }
        }
        do {
            try validate(); try await checkAttachment(token)
            let nonce = UUID(), request = try SNESLibraryDiscardUploadCommands.prepare(plan: plan, contextSHA256: value.sha256,
                runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: nonce)
            let raw = try await io.discardUpload(context: value, plan: plan, reconciliation: reconciliation, challenge: nonce)
            try validate(); try await checkAttachment(token)
            let upload = try SNESLibraryDiscardUploadInspection(raw, request: request)
            let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: before.inventory, upload: upload.upload)
            let previewID = UUID(), previewRaw = try await io.discardPreview(context: value, plan: plan, scope: scope, reconciliation: reconciliation, challenge: previewID)
            try validate(); try await checkAttachment(token)
            return .init(scope: scope, preview: try .init(previewRaw, scope: scope, challenge: previewID, contextSHA256: value.sha256))
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    func previewCleanup(plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan,
                        reconciliation: SNESLibraryReconciliationPermit? = nil) async throws -> SNESLibraryCleanupObservation {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try plan.requireOwner(value); try scope.validateSources(); try reconciliation?.requireOwner(value)
        let before = try await observe(value, reconciliation: reconciliation)
        try scope.requireCurrent(plan, inventory: before.inventory)
        guard !busy, !backingUp, connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        func validate() throws {
            try check(token)
            guard connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.disconnected }
            try plan.requireOwner(value); try scope.validateSources(); try reconciliation?.requireOwner(value)
        }
        do {
            try validate(); try await checkAttachment(token); try validate()
            let nonce = UUID(), raw = try await io.cleanupPreview(context: value, plan: plan, scope: scope, reconciliation: reconciliation, challenge: nonce)
            try validate(); try await checkAttachment(token); try validate()
            // Keep the actual target preview last so its freshness budget reaches the user's review.
            // This is inert evidence; the native removal path still checks the working library and exact target tokens again.
            let result = try SNESLibraryCleanupObservation(raw, scope: scope, challenge: nonce, contextSHA256: value.sha256)
            try validate(); try scope.validateSources()
            return result
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    func removeTemporary(plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation,
                         permit: SNESLibraryCleanupPermit) async throws -> SNESLibraryCleanupResult {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(value); try permit.require(plan: plan, scope: scope, preview: preview)
        guard preview.contextSHA256 == value.sha256, Date().timeIntervalSince(preview.measuredAt) >= 0,
              Date().timeIntervalSince(preview.measuredAt) <= 60 else { throw SNESLibraryInventory.failure() }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation, reconciliation = permit.reconciliation
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            try plan.requireOwner(value); try permit.require(plan: plan, scope: scope, preview: preview); try reconciliation.requireOwner(value)
        }
        do {
            let before = try await observeLocked(value, reconciliation: reconciliation, token: token)
            try validate(); try scope.requireCurrent(plan, inventory: before.inventory); try await checkAttachment(token)
            let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: preview, runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: permit.challenge)
            let raw = try await io.removeLibraryTemporary(context: value, plan: plan, scope: scope, preview: preview, permit: permit)
            try validate(); try await checkAttachment(token)
            _ = try SNESLibraryCleanupReceipt(raw, request: request, scope: scope)
            let nonce = UUID(), finalRaw = try await io.cleanupPreview(context: value, plan: plan, scope: scope, reconciliation: reconciliation, challenge: nonce)
            try validate(); try await checkAttachment(token)
            let gone = try SNESLibraryCleanupObservation(finalRaw, scope: scope, challenge: nonce, contextSHA256: value.sha256)
            let after = try await observeLocked(value, reconciliation: reconciliation, token: token)
            try validate(); try await checkAttachment(token)
            return try SNESLibraryCleanupResult(plan: plan, scope: scope, preview: preview, permit: permit, request: request, raw: raw, after: gone, inventory: after.inventory)
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    func discardCopy(plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation,
                         permit: SNESLibraryDiscardPermit) async throws -> SNESLibraryDiscardResult {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(value); try permit.require(plan: plan, scope: scope, preview: preview)
        guard permit.attachment == attachment else { throw SNESLibraryInventory.failure() }
        guard preview.contextSHA256 == value.sha256, Date().timeIntervalSince(preview.measuredAt) >= 0,
              Date().timeIntervalSince(preview.measuredAt) <= 60 else { throw SNESLibraryInventory.failure() }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation, reconciliation = permit.reconciliation
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            try plan.requireOwner(value); try permit.require(plan: plan, scope: scope, preview: preview); try reconciliation.requireOwner(value)
        }
        do {
            let before = try await observeLocked(value, reconciliation: reconciliation, token: token)
            try validate(); try scope.requireCurrent(plan, inventory: before.inventory); try await checkAttachment(token)
            let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: preview, runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: permit.challenge)
            let raw = try await io.discardLibraryCopy(context: value, plan: plan, scope: scope, preview: preview, permit: permit)
            try validate(); try await checkAttachment(token)
            _ = try SNESLibraryCleanupReceipt(raw, request: request, scope: scope)
            let nonce = UUID(), finalRaw = try await io.discardPreview(context: value, plan: plan, scope: scope, reconciliation: reconciliation, challenge: nonce)
            try validate(); try await checkAttachment(token)
            let gone = try SNESLibraryCleanupObservation(finalRaw, scope: scope, challenge: nonce, contextSHA256: value.sha256)
            let after = try await observeLocked(value, reconciliation: reconciliation, token: token)
            try validate(); try await checkAttachment(token)
            return try SNESLibraryDiscardResult(plan: plan, scope: scope, preview: preview, permit: permit, request: request, raw: raw, after: gone, inventory: after.inventory)
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    private func supportCurrent(_ value:SNESLibraryContext,token:Int) async throws {
        try check(token);try value.requireCurrent(attachment:attachment,sessionID:value.sessionID)
        try await checkAttachment(token)
    }
    /// Read-only; independently verified helper bytes and a current connection are required.
    func checkCompatibilityInstalledSupport(helperSHA256: String) async throws -> Data {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            let expected = try SNESCompatibilityInstalledSupportCommand.prepare(helperSHA256: helperSHA256)
            try await supportCurrent(value, token: token)
            let data = try await io.compatibilityInstalledSupport(context: value, helperSHA256: helperSHA256)
            try await supportCurrent(value, token: token)
            guard try expected.validateReceipt(data) else { throw SNESLibraryMenu.failure() }
            return data
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Read-only; caller must obtain the helper hash from a verified install.
    /// This does not install the helper or enable compatibility game launch.
    func preflightCompatibility(request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            let expected = try SNESCompatibilityPreflightCommand.prepare(request: request, helperSHA256: helperSHA256)
            try await supportCurrent(value, token: token)
            let data = try await io.compatibilityPreflight(context: value, request: request, helperSHA256: helperSHA256)
            try await supportCurrent(value, token: token)
            try request.verifySource()
            guard try expected.validateReceipt(data) else { throw SNESLibraryMenu.failure() }
            return data
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Read-only discovered sessions; no result authorizes recovery.
    func captureCompatibilityManagerInventory(game: Game, source: SNESLibraryROMSource, helperSHA256: String) async throws -> SNESCompatibilityManagerInventory.Observation {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            _ = try SNESCompatibilityManagerInventory.prepare(game: game, source: source, helperSHA256: helperSHA256)
            try await supportCurrent(value, token: token)
            let result = try await io.compatibilityManagerInventory(context: value, game: game, source: source, helperSHA256: helperSHA256)
            try await supportCurrent(value, token: token)
            try source.verify()
            return result
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Read-only correlation with a checked attachment. It does not prove
    /// console identity, stopped writers, or authorize any restoration.
    func captureCompatibilityRecovery(request: SNESCompatibilityLaunchRequest, helperSHA256: String,
                                      directory: URL, backup: SNESLibraryBackup) async throws -> SNESRecoveryConsoleObservation {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            _ = try SNESCompatibilityRecoveryCommand.prepare(request: request, helperSHA256: helperSHA256)
            return try await SNESCompatibilityRecoveryCapture.read(directory: directory, backup: backup, request: request,
                validate: { try await self.supportCurrent(value, token: token) },
                read: { try await self.io.compatibilityRecovery(context: value, request: request, helperSHA256: helperSHA256) })
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Read-only evidence. The caller independently authenticates the console,
    /// excludes writers and supplies the already-reviewed state digest.
    func captureCompatibilityRetainedState(request: SNESCompatibilityLaunchRequest, game: Game, helperSHA256: String,
                                           managerRecord: Data, expectedManagerSavePath: String,
                                           expectedManagerImagePath: String?, expectedSHA256: String,
                                           expectedManagerLoadPath: String? = nil) async throws -> SNESCompatibilitySave {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            let paired = expectedManagerImagePath != nil
            _ = try SNESCompatibilityRecoveryCommand.prepareRetainedState(request: request, helperSHA256: helperSHA256, paired: paired)
            return try await SNESRetainedStateObservation.capture(managerRecord: managerRecord, request: request, game: game,
                expectedManagerSavePath: expectedManagerSavePath, expectedManagerImagePath: expectedManagerImagePath, expectedSHA256: expectedSHA256, expectedManagerLoadPath: expectedManagerLoadPath,
                validate: { try await self.supportCurrent(value, token: token) },
                read: { try await self.io.compatibilityRetainedState(context: value, request: request, helperSHA256: helperSHA256, paired: paired) })
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// The caller independently authenticates the console, excludes writers
    /// and supplies a previously reviewed image digest. No restore occurs.
    func captureCompatibilityRetainedImage(request: SNESCompatibilityLaunchRequest, helperSHA256: String,
                                           managerRecord: Data, expectedManagerSavePath: String?,
                                           expectedManagerImagePath: String, expectedSHA256: String, retired: Bool = false,
                                           expectedManagerLoadPath: String? = nil) async throws -> Data {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            let paired = expectedManagerSavePath != nil
            _ = try SNESCompatibilityRecoveryCommand.prepareRetainedImage(request: request, helperSHA256: helperSHA256, paired: paired, retired: retired)
            return try await SNESRetainedImageObservation.capture(managerRecord: managerRecord, request: request,
                expectedManagerSavePath: expectedManagerSavePath, expectedManagerImagePath: expectedManagerImagePath, expectedSHA256: expectedSHA256, retired: retired, expectedManagerLoadPath: expectedManagerLoadPath,
                validate: { try await self.supportCurrent(value, token: token) },
                read: { if retired { return try await self.io.compatibilityRetiredImage(context: value, request: request, helperSHA256: helperSHA256, paired: paired) }; return try await self.io.compatibilityRetainedImage(context: value, request: request, helperSHA256: helperSHA256, paired: paired) })
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Read-only evidence; callers authenticate the console, exclude writers and provide an independent digest.
    func captureCompatibilityStateArchive(request: SNESCompatibilityLaunchRequest, game: Game, helperSHA256: String,
                                          managerRecord: Data, expectedSHA256: String, expectedManagerLoadPath: String? = nil) async throws -> SNESCompatibilitySave {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            _ = try SNESCompatibilityRecoveryCommand.prepareStateArchive(request: request, helperSHA256: helperSHA256)
            return try await SNESStateArchiveObservation.capture(managerRecord: managerRecord, request: request, game: game, expectedSHA256: expectedSHA256, expectedManagerLoadPath: expectedManagerLoadPath,
                validate: { try await self.supportCurrent(value, token: token) },
                read: { try await self.io.compatibilityStateArchive(context: value, request: request, helperSHA256: helperSHA256) })
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Read-only evidence; callers authenticate the console, exclude writers and provide an independent digest.
    func captureCompatibilityRetainedTime(request: SNESCompatibilityLaunchRequest, helperSHA256: String,
                                          managerRecord: Data, expectedLoadPath: String, expectedSHA256: String, expectedManagerLoadPath: String? = nil) async throws -> Data {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            _ = try SNESCompatibilityRecoveryCommand.prepareRetainedTime(request: request, helperSHA256: helperSHA256)
            return try await SNESRetainedTimeObservation.capture(managerRecord: managerRecord, request: request,
                expectedLoadPath: expectedLoadPath, expectedSHA256: expectedSHA256, expectedManagerLoadPath: expectedManagerLoadPath,
                validate: { try await self.supportCurrent(value, token: token) },
                read: { try await self.io.compatibilityRetainedTime(context: value, request: request, helperSHA256: helperSHA256) })
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Read-only current save evidence, bracketed by matching session
    /// observations. This never establishes exclusive access or authorizes restore.
    func captureCompatibilityCurrent(request: SNESCompatibilityLaunchRequest, helperSHA256: String,
                                     directory: URL, backup: SNESLibraryBackup, region: SNESRecoveryRegion) async throws -> SNESRecoveryCurrentCapture {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            return try await captureCompatibilityCurrentLocked(value, token: token, request: request, helperSHA256: helperSHA256,
                                                               directory: directory, backup: backup, region: region)
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Caller owns the connection's busy reservation for this entire capture.
    private func captureCompatibilityCurrentLocked(_ value: SNESLibraryContext, token: Int, request: SNESCompatibilityLaunchRequest,
                                                   helperSHA256: String, directory: URL, backup: SNESLibraryBackup,
                                                   region: SNESRecoveryRegion) async throws -> SNESRecoveryCurrentCapture {
        _ = try SNESCompatibilityRecoveryCommand.prepareCurrent(request: request, helperSHA256: helperSHA256, region: region)
        let validate: @Sendable () async throws -> Void = { try await self.supportCurrent(value, token: token) }
        let readBinding: @Sendable () async throws -> Data = { try await self.io.compatibilityRecovery(context: value, request: request, helperSHA256: helperSHA256) }
        let before = try await SNESCompatibilityRecoveryCapture.read(directory: directory, backup: backup, request: request, validate: validate, read: readBinding)
        let current = try await SNESCompatibilityRecoveryCapture.readCurrent(observation: before, request: request, region: region, validate: validate,
            read: { try await self.io.compatibilityRecoveryCurrent(context: value, request: request, helperSHA256: helperSHA256, region: region) })
        let after = try await SNESCompatibilityRecoveryCapture.read(directory: directory, backup: backup, request: request, validate: validate, read: readBinding)
        guard before == after else { throw SNESCompatibilitySupportFrame.failure() }
        return .init(observation: before, current: current)
    }
    /// Explicit Mac retention only; this does not authorize or perform a
    /// console restore. Partial files are retained for inspection on failure.
    func retainCompatibilityCurrent(request: SNESCompatibilityLaunchRequest, helperSHA256: String,
                                    directory: URL, backup: SNESLibraryBackup, region: SNESRecoveryRegion,
                                    root: URL) async throws -> SNESCompatibilityCurrentEvidence {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        let capture: SNESRecoveryCurrentCapture
        do {
            capture = try await captureCompatibilityCurrentLocked(value, token: token, request: request, helperSHA256: helperSHA256,
                                                                  directory: directory, backup: backup, region: region)
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
        try await supportCurrent(value, token: token)
        let evidence = try SNESCompatibilityCurrentEvidence.createOrResume(root: root, referenceDirectory: directory, backup: backup,
            request: request, observation: capture.observation, region: region, current: capture.current)
        try await supportCurrent(value, token: token)
        return evidence
    }
    /// Checks only the selected workspace over the current connection. It does
    /// not validate restore bytes, stop writers or authorize a console write.
    func inspectCompatibilityClockRecovery(plan: SNESClockRecoveryPlan, helperSHA256: String) async throws -> Data {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            return try await SNESClockRecoveryInspection.capture(plan: plan, helperSHA256: helperSHA256,
                validate: { try await self.supportCurrent(value, token: token) },
                read: { try await self.io.inspectClockRecovery(context: value, plan: plan, helperSHA256: helperSHA256) })
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Read-only workspace inspection; the helper hash must come from a
    /// verified install. This never authorizes or performs restoration.
    func inspectCompatibilityBatteryRecovery(plan: SNESBatteryRecoveryPlan, helperSHA256: String) async throws -> Data {
        guard let value = context, connected, !closed else { throw LegacyInspectionError.disconnected }
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }; let token = generation
        do {
            return try await SNESBatteryRecoveryInspection.capture(plan: plan, helperSHA256: helperSHA256,
                validate: { try await self.supportCurrent(value, token: token) },
                read: { try await self.io.inspectBatteryRecovery(context: value, plan: plan, helperSHA256: helperSHA256) })
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    func captureCompatibilitySupport() async throws -> SNESCompatibilityConsoleSupport {
        guard let value=context,connected,!closed else {throw LegacyInspectionError.disconnected}
        guard !busy,!backingUp else {throw LegacyInspectionError.busy}
        busy=true;defer{busy=false};let token=generation
        do {
            try await supportCurrent(value,token:token)
            let firstNonce=UUID(),firstRaw=try await io.report(installation:value.installation,challenge:firstNonce)
            try await supportCurrent(value,token:token)
            let first=try SNESStartupTrialReport(firstRaw,expected:value.installation.expected,challenge:firstNonce)
            let capture=try await SNESCompatibilitySupportCapture.read(context:value.sha256,hwid:value.installation.expected.hwid,
                validate:{try await self.supportCurrent(value,token:token)},
                read:{try await self.io.compatibilitySupport(context:value,challenge:$0)})
            let lastNonce=UUID(),lastRaw=try await io.report(installation:value.installation,challenge:lastNonce)
            try await supportCurrent(value,token:token)
            let last=try SNESStartupTrialReport(lastRaw,expected:value.installation.expected,challenge:lastNonce)
            guard first.mcpPID==last.mcpPID,first.daemonPID==last.daemonPID else {throw SNESCompatibilitySupportFrame.failure()}
            return .init(capture:capture,reports:[firstRaw,lastRaw],reportChallenges:[firstNonce,lastNonce])
        } catch {
            context=nil;connected=false
            if !closed {closed=true;generation+=1;await io.disconnect()}
            throw error
        }
    }
    func capturePowerInput() async throws -> (frame:SNESPowerInputFrame,challenge:UUID,report:Data,reportChallenge:UUID) {
        guard let value=context,connected,!closed else {throw LegacyInspectionError.disconnected}
        guard !busy,!backingUp else {throw LegacyInspectionError.busy}
        busy=true;defer{busy=false};let token=generation
        do {
            try await supportCurrent(value,token:token)
            let reportNonce=UUID(),report=try await io.report(installation:value.installation,challenge:reportNonce)
            try await supportCurrent(value,token:token)
            _=try SNESStartupTrialReport(report,expected:value.installation.expected,challenge:reportNonce)
            let nonce=UUID(),raw=try await io.powerInput(context:value,challenge:nonce)
            try check(token)
            let frame=try SNESPowerInputFrame(raw,challenge:nonce,context:value.sha256,hwid:value.installation.expected.hwid)
            return (frame,nonce,report,reportNonce)
        } catch {
            context=nil;connected=false
            if !closed {closed=true;generation+=1;await io.disconnect()}
            throw error
        }
    }
    func captureResetInput() async throws -> (frame:SNESCompatibilityInputFrame,challenge:UUID,reports:[Data],reportChallenges:[UUID]) {
        guard let value=context,connected,!closed else {throw LegacyInspectionError.disconnected}
        guard !busy,!backingUp else {throw LegacyInspectionError.busy}
        busy=true;defer{busy=false};let token=generation
        do {
            try await supportCurrent(value,token:token)
            let firstNonce=UUID(),firstRaw=try await io.report(installation:value.installation,challenge:firstNonce)
            try await supportCurrent(value,token:token)
            let first=try SNESStartupTrialReport(firstRaw,expected:value.installation.expected,challenge:firstNonce)
            FileHandle.standardError.write(Data("Preparing the 60-second RESET trace; wait for the separate tap instruction.\n".utf8))
            let nonce=UUID(),raw=try await io.resetInput(context:value,challenge:nonce)
            try await supportCurrent(value,token:token)
            let frame=try SNESCompatibilityInputFrame(raw,challenge:nonce,context:value.sha256,hwid:value.installation.expected.hwid)
            let lastNonce=UUID(),lastRaw=try await io.report(installation:value.installation,challenge:lastNonce)
            try await supportCurrent(value,token:token)
            let last=try SNESStartupTrialReport(lastRaw,expected:value.installation.expected,challenge:lastNonce)
            guard first.mcpPID==last.mcpPID,first.daemonPID==last.daemonPID else {throw SNESCompatibilitySupportFrame.failure()}
            return (frame,nonce,[firstRaw,lastRaw],[firstNonce,lastNonce])
        } catch {
            context=nil;connected=false
            if !closed {closed=true;generation+=1;await io.disconnect()}
            throw error
        }
    }
    func captureFrontendSupport() async throws -> SNESFrontendConsoleSupport {
        guard let value=context,connected,!closed else {throw LegacyInspectionError.disconnected}
        guard !busy,!backingUp else {throw LegacyInspectionError.busy}
        busy=true;defer{busy=false};let token=generation
        do {
            try await supportCurrent(value,token:token)
            let firstNonce=UUID(),firstRaw=try await io.report(installation:value.installation,challenge:firstNonce)
            try await supportCurrent(value,token:token)
            let first=try SNESStartupTrialReport(firstRaw,expected:value.installation.expected,challenge:firstNonce)
            let capture=try await SNESFrontendSupportCapture.read(context:value.sha256,hwid:value.installation.expected.hwid,
                validate:{try await self.supportCurrent(value,token:token)},
                read:{try await self.io.frontendSupport(context:value,challenge:$0)})
            let lastNonce=UUID(),lastRaw=try await io.report(installation:value.installation,challenge:lastNonce)
            try await supportCurrent(value,token:token)
            let last=try SNESStartupTrialReport(lastRaw,expected:value.installation.expected,challenge:lastNonce)
            guard first.mcpPID==last.mcpPID,first.daemonPID==last.daemonPID else {throw SNESCompatibilitySupportFrame.failure()}
            return .init(capture:capture,reports:[firstRaw,lastRaw],reportChallenges:[firstNonce,lastNonce])
        } catch {
            context=nil;connected=false
            if !closed {closed=true;generation+=1;await io.disconnect()}
            throw error
        }
    }
    func verifyRestarted(plan: SNESLibrarySyncPlan, previousAttachment: RecoveryProbeUSBDevice,destination:SNESLibraryColdEvidence.Destination = .updated) async throws -> SNESLibraryColdEvidence {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        guard !backingUp else { throw LegacyInspectionError.busy }
        try plan.requireOwner(value)
        let observation = try await observe(value)
        try await requireCurrent(observation); try plan.requireOwner(value)
        var pending:SNESLibraryRollbackPendingReceipt?
        if destination == .previous {
            let nonce=UUID(),request=try SNESLibraryRollbackPendingCommands.prepare(id:plan.material.menu.id,context:value.sha256,hwid:plan.before.hwid,runtime:value.installation.expected.runtimeSHA256,challenge:nonce)
            let raw=try await io.rollbackPendingAbsent(context:value,plan:plan,challenge:nonce)
            try await requireCurrent(observation);try plan.requireOwner(value)
            pending=try .init(raw,request:request)
        }
        return try SNESLibraryColdEvidence(plan: plan, previousAttachment: previousAttachment, attachment: attachment,
            expected: value.installation.expected, inventory: observation.inventory,
            challenges: observation.reportChallenges, reports: observation.reports,destination:destination,pendingReceipt:pending)
    }
    func rollbackReady(plan:SNESLibrarySyncPlan) async throws->(RecoveryProbeUSBDevice,SNESLibraryInventory) {
        guard let value=context else {throw LegacyInspectionError.disconnected}
        try plan.requireOwner(value)
        let observation=try await observe(value)
        try await requireCurrent(observation);try plan.requireOwner(value)
        try SNESLibraryActiveCheck.require(plan,inventory:observation.inventory,preserveProfiles:false)
        return (attachment,observation.inventory)
    }
    func restorePrevious(plan:SNESLibrarySyncPlan,permit:SNESLibraryRollbackPermit) async throws->SNESLibraryRollbackResult {
        guard let value=context else {throw LegacyInspectionError.disconnected}
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(value);try permit.require(plan,attachment:attachment);try await requireCurrent(value)
        guard !busy,!backingUp else {throw LegacyInspectionError.busy}
        busy=true;defer {busy=false}
        let token=generation
        func validate()throws {
            try check(token);try value.requireCurrent(attachment:attachment,sessionID:value.sessionID)
            try plan.requireOwner(value);try permit.require(plan,attachment:attachment)
        }
        do {
            let before=try await observeLocked(value,token:token)
            try validate();try await checkAttachment(token)
            guard before.inventory.stateSHA256==permit.expectedStateSHA256 else {throw SNESLibraryInventory.failure()}
            try SNESLibraryActiveCheck.require(plan,inventory:before.inventory,preserveProfiles:false)
            let request=try SNESLibraryRollbackCommands.prepare(menu:plan.material.menu,previous:plan.before.selection,current:before.inventory,
                runtimeSHA256:value.installation.expected.runtimeSHA256,challenge:permit.challenge,recoverPending:permit.allowsPendingRecovery)
            let raw=try await io.restoreLibrarySelection(context:value,plan:plan,permit:permit,before:before.inventory)
            try validate();try await checkAttachment(token)
            _=try SNESLibraryRollbackReceipt(raw,request:request)
            // The old display remains until the user restarts normally.
            let nonce=UUID(),inventoryRaw=try await io.libraryInventory(context:value,challenge:nonce)
            try validate();try await checkAttachment(token)
            let after=try SNESLibraryInventory(raw:inventoryRaw,challenge:nonce,contextSHA256:value.sha256,hwid:value.installation.expected.hwid,catalogSHA256:value.installation.catalogContentSHA256)
            return try .init(plan:plan,permit:permit,request:request,raw:raw,before:before.inventory,after:after)
        } catch {
            context=nil;connected=false
            if !closed {closed=true;generation+=1;await io.disconnect()}
            throw error
        }
    }
    func selectionAttachment(plan: SNESLibrarySyncPlan) async throws -> RecoveryProbeUSBDevice {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try plan.requireOwner(value); try await requireCurrent(value)
        return attachment
    }
    func saveSelection(plan: SNESLibrarySyncPlan, permit: SNESLibrarySelectionPermit) async throws -> SNESLibrarySelectionResult {
        guard let value = context else { throw LegacyInspectionError.disconnected }
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(value); try permit.require(plan, attachment: attachment)
        try await requireCurrent(value)
        guard !busy, !backingUp else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation
        func validate() throws {
            try check(token); try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            try plan.requireOwner(value); try permit.require(plan, attachment: attachment)
        }
        do {
            let before = try await observeLocked(value, token: token)
            try validate(); try await checkAttachment(token)
            try SNESLibraryInactiveCheck.require(plan, inventory: before.inventory)
            let request = try SNESLibrarySelectionCommands.prepare(menu: plan.material.menu, before: before.inventory,
                runtimeSHA256: value.installation.expected.runtimeSHA256, challenge: permit.challenge)
            try validate(); try await checkAttachment(token)
            let raw = try await io.saveLibrarySelection(context: value, plan: plan, permit: permit, before: before.inventory)
            try validate(); try await checkAttachment(token)
            _ = try SNESLibrarySelectionReceipt(raw, request: request)
            // The old displayed menu remains until restart: do not demand its config already matches the newly saved choice.
            let nonce = UUID(), inventoryRaw = try await io.libraryInventory(context: value, challenge: nonce)
            try validate(); try await checkAttachment(token)
            let after = try SNESLibraryInventory(raw: inventoryRaw, challenge: nonce, contextSHA256: value.sha256,
                hwid: value.installation.expected.hwid, catalogSHA256: value.installation.catalogContentSHA256)
            return try SNESLibrarySelectionResult(plan: plan, permit: permit, request: request, raw: raw, after: after)
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    /// Checks host ownership/attachment only. Mutations must obtain their own fresh state comparison.
    func requireCurrent(_ observation: SNESLibraryObservation) async throws {
        try observation.reconciliationPermit?.requireOwner(observation.context)
        try await requireCurrent(observation.context)
    }
    func captureBackup(_ observation: SNESLibraryObservation, root: URL, material: SNESLibraryMaterial? = nil, reusing backups: [SNESLibraryBackup] = [], allowCreation: Bool = true, forceNew: Bool = false) async throws -> SNESLibraryBackup {
        guard !backingUp else { throw LegacyInspectionError.busy }
        backingUp = true; defer { backingUp = false }
        try await requireCurrent(observation)
        for backup in backups where !forceNew && backup.inventory.snapshotSHA256 == observation.inventory.snapshotSHA256 {
            try backup.validate()
            let fresh = try await observe(observation.context, reconciliation: observation.reconciliationPermit)
            guard fresh.inventory.snapshotSHA256 == observation.inventory.snapshotSHA256, fresh.inventory.stateSHA256 == observation.inventory.stateSHA256 else { throw SNESLibraryInventory.failure() }
            try backup.validate(); return backup
        }
        let reuse = try SNESLibraryBackupReuse.prepare(inventory: observation.inventory, material: material, backups: backups)
        let saved = try await SNESLibraryBackup.capture(inventory: observation.inventory, root: root,
            read: { file, offset in
                if let bytes = try reuse.chunk(file: file, offset: offset) { return bytes }
                return try await self.readBackupChunk(observation, file: file, offset: offset)
            },
            refresh: { try await self.observe(observation.context, reconciliation: observation.reconciliationPermit).inventory }, allowCreation: allowCreation, forceNew: forceNew)
        try await requireCurrent(observation); return saved
    }
    func readBackupChunk(_ observation: SNESLibraryObservation, file: SNESLibraryInventory.File, offset: Int) async throws -> Data {
        guard observation.inventory.files.contains(file) else { throw SNESLibraryInventory.failure() }
        _ = try SNESLibraryBackupChunk.count(file: file, offset: offset)
        try await requireCurrent(observation)
        guard !busy else { throw LegacyInspectionError.busy }
        busy = true; defer { busy = false }
        let token = generation, value = observation.context, challenge = UUID()
        do {
            try check(token); try await checkAttachment(token)
            let raw = try await io.libraryChunk(context: value, file: file, offset: offset, challenge: challenge)
            try check(token); try await checkAttachment(token)
            try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
            return try SNESLibraryBackupChunk(raw: raw, file: file, offset: offset, challenge: challenge, contextSHA256: value.sha256).bytes
        } catch {
            context = nil; connected = false
            if !closed { closed = true; generation += 1; await io.disconnect() }
            throw error
        }
    }
    func disconnect() async {
        generation += 1; context = nil; connected = false
        guard !closed else { return }; closed = true
        await io.disconnect()
    }
    func requireCurrent(_ value: SNESLibraryContext) async throws {
        guard !busy, connected, !closed, context?.sha256 == value.sha256 else { throw LegacyInspectionError.disconnected }
        let token = generation, stamp = operationStamp
        try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
        let devices = try await io.inventory()
        try Task.checkCancellation()
        guard generation == token, operationStamp == stamp, !busy, connected, !closed, context?.sha256 == value.sha256, devices == [attachment] else { throw LegacyInspectionError.disconnected }
        try value.requireCurrent(attachment: attachment, sessionID: value.sessionID)
    }
}

actor NativeSNESLibraryIO: SNESLibraryConnectionIO {
    private static let ownerCache = SNESLibraryOwnerCache<SNESLibraryInstallation>()
    private let client: LegacyInspectionClient
    init(attachment: RecoveryProbeUSBDevice) {
        client = LegacyInspectionClient(transport: SNESStartupTrialUSBTransport(expected: attachment), maximumOutputBytes: SNESLibraryInventory.maximumFrameBytes)
    }
    func inventory() throws -> [RecoveryProbeUSBDevice] { try Task.checkCancellation(); return try RecoveryProbeUSBRegistry.inventory() }
    func open() async throws { try await client.connect(timeoutMilliseconds: 10000) }
    func identity(challenge: UUID) async throws -> Data {
        let result = try await client.readSNESLibraryIdentity(challenge: challenge)
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData.count <= 1024 else { throw SNESLibraryInstallation.failure() }
        return result.stdoutData
    }
    func report(installation: SNESLibraryInstallation, challenge: UUID) async throws -> Data {
        try installation.validate()
        let result = try await client.readSNESStartupTrial(installation.accepted.material.trial, challenge: challenge)
        try installation.validate()
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData.count <= 16384 else { throw SNESLibraryInstallation.failure() }
        return result.stdoutData
    }
    func compatibilityInstalledSupport(context: SNESLibraryContext, helperSHA256: String) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.checkSNESCompatibilityInstalledSupport(context, helperSHA256: helperSHA256)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 256)
    }
    func compatibilityPreflight(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.preflightSNESCompatibility(context, request: request, helperSHA256: helperSHA256)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 1024)
    }
    func compatibilityManagerInventory(context: SNESLibraryContext, game: Game, source: SNESLibraryROMSource, helperSHA256: String) async throws -> SNESCompatibilityManagerInventory.Observation {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.readSNESCompatibilityManagerInventory(context, game: game, source: source, helperSHA256: helperSHA256)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return result
    }
    func compatibilityRecovery(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.readSNESCompatibilityRecovery(context, request: request, helperSHA256: helperSHA256)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 24576)
    }
    func compatibilityRecoveryCurrent(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, region: SNESRecoveryRegion) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.readSNESCompatibilityCurrent(context, request: request, helperSHA256: helperSHA256, region: region)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 128 * 1024 + 256)
    }
    func compatibilityRetainedState(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, paired: Bool) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.readSNESCompatibilityRetainedState(context, request: request, helperSHA256: helperSHA256, paired: paired)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 16 * 1024 * 1024 + 24576)
    }
    func compatibilityRetainedImage(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, paired: Bool) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.readSNESCompatibilityRetainedImage(context, request: request, helperSHA256: helperSHA256, paired: paired)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 8 * 1024 * 1024 + 24576)
    }
    func compatibilityRetiredImage(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, paired: Bool) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.readSNESCompatibilityRetainedImage(context, request: request, helperSHA256: helperSHA256, paired: paired, retired: true)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 8 * 1024 * 1024 + 24576)
    }
    func compatibilityStateArchive(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.readSNESCompatibilityStateArchive(context, request: request, helperSHA256: helperSHA256)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 16 * 1024 * 1024 + 24576)
    }
    func compatibilityRetainedTime(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.readSNESCompatibilityRetainedTime(context, request: request, helperSHA256: helperSHA256)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 24576)
    }
    func inspectClockRecovery(context: SNESLibraryContext, plan: SNESClockRecoveryPlan, helperSHA256: String) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.inspectSNESClockRecovery(context, plan: plan, helperSHA256: helperSHA256)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 128)
    }
    func inspectBatteryRecovery(context: SNESLibraryContext, plan: SNESBatteryRecoveryPlan, helperSHA256: String) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try await client.inspectSNESBatteryRecovery(context, plan: plan, helperSHA256: helperSHA256)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESCompatibilitySupportFrame.failure() }
        return try checkedResult(result, maximum: 128)
    }
    func compatibilitySupport(context:SNESLibraryContext,challenge:UUID) async throws -> Data {
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory()==[context.attachment] else {throw SNESCompatibilitySupportFrame.failure()}
        let result=try await client.readSNESCompatibilitySupport(context,challenge:challenge)
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory()==[context.attachment] else {throw SNESCompatibilitySupportFrame.failure()}
        return try checkedResult(result,maximum:SNESCompatibilitySupportFrame.maximumBytes)
    }
    func powerInput(context:SNESLibraryContext,challenge:UUID) async throws -> Data {
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory()==[context.attachment] else {throw SNESCompatibilitySupportFrame.failure()}
        let result=try await client.readSNESPowerInput(context,challenge:challenge)
        #if RECOVERY_DIAGNOSTIC
        FileHandle.standardError.write(Data("POWER_CAPTURE_RESULT exit=\(result.exitCode) stdout=\(result.stdoutData.count)\n".utf8))
        #endif
        return try SNESPowerInputCommand.checkedResponse(result,challenge:challenge)
    }
    func resetInput(context:SNESLibraryContext,challenge:UUID) async throws -> Data {
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory()==[context.attachment] else {throw SNESCompatibilitySupportFrame.failure()}
        let result=try await client.readSNESResetInput(context,challenge:challenge)
        #if RECOVERY_DIAGNOSTIC
        let detail=String(result.stderr.prefix(256))
        FileHandle.standardError.write(Data("RESET command exit=\(result.exitCode) stdout=\(result.stdoutData.count) stderr=\(detail)\n".utf8))
        #endif
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory()==[context.attachment] else {throw SNESCompatibilitySupportFrame.failure()}
        return try checkedResult(result,maximum:SNESCompatibilityInputFrame.maximumBytes)
    }
    func frontendSupport(context:SNESLibraryContext,challenge:UUID) async throws -> Data {
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory()==[context.attachment] else {throw SNESCompatibilitySupportFrame.failure()}
        let result=try await client.readSNESFrontendSupport(context,challenge:challenge)
        #if RECOVERY_DIAGNOSTIC
        let detail=String(result.stderr.prefix(256))
        FileHandle.standardError.write(Data("Frontend command exit=\(result.exitCode) stdout=\(result.stdoutData.count) stderr=\(detail)\n".utf8))
        #endif
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        guard try RecoveryProbeUSBRegistry.inventory()==[context.attachment] else {throw SNESCompatibilitySupportFrame.failure()}
        return try checkedResult(result,maximum:SNESFrontendSupportFrame.maximumBytes)
    }
    func libraryInventory(context: SNESLibraryContext, challenge: UUID) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let result = try await client.readSNESLibraryInventory(context, challenge: challenge)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        return try checkedResult(result, maximum: SNESLibraryInventory.maximumFrameBytes)
    }
    func inspectReplacementSaveStage(context: SNESLibraryContext, request: SNESReplacementSaveStageInspection.Request) async throws -> SNESReplacementSaveStageInspectionReceipt.Outcome {
        try request.require(context)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let nonce = UUID(), raw = try await libraryInventory(context: context, challenge: nonce)
        let fresh = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, catalogSHA256: context.installation.catalogContentSHA256)
        try request.requireInventory(fresh); try request.require(context)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let outcome = try await client.inspectSNESReplacementSaveStage(context, request: request)
        try request.require(context)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        return outcome
    }
    func stageReplacementSave(context: SNESLibraryContext, request: SNESReplacementSaveStageCommands.Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.StagePermit) async throws -> SNESReplacementSaveStageReceipt {
        try permit.requireOwner(context); try permit.require(request: request, before: before)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let nonce = UUID(), raw = try await libraryInventory(context: context, challenge: nonce)
        let fresh = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, catalogSHA256: context.installation.catalogContentSHA256)
        try permit.requireOwner(context); try permit.require(request: request, before: fresh)
        guard fresh.stateSHA256 == before.stateSHA256, try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let receipt = try await client.stageSNESReplacementSave(context, request: request, before: fresh, permit: permit)
        try permit.requireOwner(context); try permit.require(request: request, before: fresh)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        return receipt
    }
    func deliverReplacementSaveHelper(context: SNESLibraryContext, request: SNESReplacementSaveHelperDelivery.Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.HelperDeliveryPermit) async throws {
        try permit.requireOwner(context); try permit.require(request: request, before: before)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let nonce = UUID(), raw = try await libraryInventory(context: context, challenge: nonce)
        let fresh = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, catalogSHA256: context.installation.catalogContentSHA256)
        try permit.requireOwner(context); try permit.require(request: request, before: fresh)
        guard fresh.stateSHA256 == before.stateSHA256, try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        try await client.deliverSNESReplacementSaveHelper(context, request: request, before: fresh, permit: permit)
        try permit.requireOwner(context); try permit.require(request: request, before: fresh)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
    }
    func publishReplacementSave(context: SNESLibraryContext, request: SNESReplacementSaveProfilePublication.Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.PublicationPermit) async throws {
        try permit.requireOwner(context); try permit.require(request: request, before: before)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let nonce = UUID(), raw = try await libraryInventory(context: context, challenge: nonce)
        let fresh = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, catalogSHA256: context.installation.catalogContentSHA256)
        try permit.requireOwner(context); try permit.require(request: request, before: fresh)
        guard fresh.stateSHA256 == before.stateSHA256, try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        try await client.publishSNESReplacementSave(context, request: request, before: fresh, permit: permit)
        try permit.requireOwner(context); try permit.require(request: request, before: fresh)
        guard try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
    }
    func recoveryInventory(context: SNESLibraryContext, permit: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> Data {
        try SNESLibraryJournalPolicy.requireOperation(permit.operation); try permit.requireOwner(context)
        let result = try await client.readSNESLibraryRecoveryInventory(context, permit: permit, challenge: challenge)
        try permit.requireOwner(context)
        return try checkedResult(result, maximum: SNESLibraryInventory.maximumFrameBytes)
    }
    func librarySpace(context: SNESLibraryContext, selection: SNESLibraryInventory.Selection, challenge: UUID) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let result = try await client.readSNESLibrarySpace(context, selection: selection, challenge: challenge)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        return try checkedResult(result, maximum: 1024)
    }
    func libraryChunk(context: SNESLibraryContext, file: SNESLibraryInventory.File, offset: Int, challenge: UUID) async throws -> Data {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let result = try await client.readSNESLibraryChunk(context, file: file, offset: offset, challenge: challenge)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        return try checkedResult(result, maximum: SNESLibraryBackupChunk.maximumBytes + 2048)
    }
    func copyLibrary(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, permit: SNESLibraryCopyPermit, before: SNESLibraryInventory) async throws -> Data {
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context); try permit.require(plan)
        // Independently refresh here too: an inert inventory cannot directly authorize this physical adapter.
        let challenge = UUID(), raw = try await libraryInventory(context: context, challenge: challenge)
        try plan.requireOwner(context); try permit.require(plan)
        let fresh = try SNESLibraryInventory(raw: raw, challenge: challenge, contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, catalogSHA256: context.installation.catalogContentSHA256)
        guard fresh.stateSHA256 == before.stateSHA256, fresh.stateSHA256 == plan.before.stateSHA256,
              fresh.contextSHA256 == plan.before.contextSHA256 else { throw SNESLibraryInventory.failure() }
        let spaceID = UUID(), spaceRaw = try await librarySpace(context: context, selection: fresh.selection, challenge: spaceID)
        try plan.requireOwner(context); try permit.require(plan)
        let space = try SNESLibrarySpace(spaceRaw, challenge: spaceID, contextSHA256: context.sha256, hwid: fresh.hwid)
        let projection = try SNESLibraryCapacity.project(menu: plan.material.menu, inventory: space.capacity(for: fresh), expectedContext: context.sha256)
        guard projection.canFit, try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let result = try await client.copySNESLibrary(context, plan: plan, permit: permit, before: fresh)
        try plan.requireOwner(context); try permit.require(plan)
        return try checkedResult(result, maximum: 4096)
    }
    func restoreLibrarySelection(context:SNESLibraryContext,plan:SNESLibrarySyncPlan,permit:SNESLibraryRollbackPermit,before:SNESLibraryInventory) async throws->Data {
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context);try permit.require(plan,attachment:context.attachment)
        let nonce=UUID(),raw=try await libraryInventory(context:context,challenge:nonce)
        let fresh=try SNESLibraryInventory(raw:raw,challenge:nonce,contextSHA256:context.sha256,hwid:context.installation.expected.hwid,catalogSHA256:context.installation.catalogContentSHA256)
        try plan.requireOwner(context);try permit.require(plan,attachment:context.attachment)
        guard fresh.stateSHA256==before.stateSHA256,fresh.stateSHA256==permit.expectedStateSHA256,try RecoveryProbeUSBRegistry.inventory()==[context.attachment] else {throw SNESLibraryInventory.failure()}
        try SNESLibraryActiveCheck.require(plan,inventory:fresh,preserveProfiles:false)
        let result=try await client.restoreSNESLibrarySelection(context,plan:plan,permit:permit,before:fresh)
        try plan.requireOwner(context);try permit.require(plan,attachment:context.attachment)
        return try checkedResult(result,maximum:4096)
    }
    func rollbackPendingAbsent(context:SNESLibraryContext,plan:SNESLibrarySyncPlan,challenge:UUID) async throws->Data {
        try plan.requireOwner(context)
        let result=try await client.inspectSNESLibraryRollback(context,plan:plan,challenge:challenge)
        try plan.requireOwner(context);return try checkedResult(result,maximum:4096)
    }
    func saveLibrarySelection(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, permit: SNESLibrarySelectionPermit, before: SNESLibraryInventory) async throws -> Data {
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context); try permit.require(plan, attachment: context.attachment)
        let nonce = UUID(), raw = try await libraryInventory(context: context, challenge: nonce)
        try plan.requireOwner(context); try permit.require(plan, attachment: context.attachment)
        let fresh = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, catalogSHA256: context.installation.catalogContentSHA256)
        guard fresh.stateSHA256 == before.stateSHA256 else { throw SNESLibraryInventory.failure() }
        try SNESLibraryInactiveCheck.require(plan, inventory: fresh)
        let spaceID = UUID(), spaceRaw = try await librarySpace(context: context, selection: fresh.selection, challenge: spaceID)
        try plan.requireOwner(context); try permit.require(plan, attachment: context.attachment)
        let space = try SNESLibrarySpace(spaceRaw, challenge: spaceID, contextSHA256: context.sha256, hwid: fresh.hwid)
        let capacity = try space.capacity(for: fresh)
        guard capacity.freeBytes >= 2 * capacity.blockSize + 32768, try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let result = try await client.saveSNESLibrarySelection(context, plan: plan, permit: permit, before: fresh)
        try plan.requireOwner(context); try permit.require(plan, attachment: context.attachment)
        return try checkedResult(result, maximum: 4096)
    }
    func cleanupPreview(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan,
                        reconciliation: SNESLibraryReconciliationPermit?, challenge: UUID) async throws -> Data {
        try plan.requireOwner(context); try scope.validateSources(); try reconciliation?.requireOwner(context)
        let nonce = UUID(), raw: Data
        if let reconciliation { raw = try await recoveryInventory(context: context, permit: reconciliation, challenge: nonce) }
        else { raw = try await libraryInventory(context: context, challenge: nonce) }
        try plan.requireOwner(context); try scope.validateSources(); try reconciliation?.requireOwner(context)
        let fresh = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: context.sha256, hwid: context.installation.expected.hwid,
            catalogSHA256: context.installation.catalogContentSHA256, excludingIncompleteMenu: reconciliation?.excludedMenuID)
        guard !fresh.incompleteNamespace || reconciliation?.allowsIncompleteNamespace == true else { throw SNESLibraryInventory.failure() }
        try scope.requireCurrent(plan, inventory: fresh)
        let result = try await client.previewSNESLibraryCleanup(context, plan: plan, scope: scope, challenge: challenge)
        try plan.requireOwner(context); try scope.validateSources(); try reconciliation?.requireOwner(context)
        return try checkedResult(result, maximum: 2 * 1024 * 1024)
    }
    func removeLibraryTemporary(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan,
                                preview: SNESLibraryCleanupObservation, permit: SNESLibraryCleanupPermit) async throws -> Data {
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        let nonce = UUID(), freshRaw = try await cleanupPreview(context: context, plan: plan, scope: scope, reconciliation: permit.reconciliation, challenge: nonce)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        let fresh = try SNESLibraryCleanupObservation(freshRaw, scope: scope, challenge: nonce, contextSHA256: context.sha256)
        guard fresh.tokensSHA256 == preview.tokensSHA256, fresh.device == preview.device,
              try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let result = try await client.removeSNESLibraryTemporary(context, plan: plan, scope: scope, preview: preview, permit: permit)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        return try checkedResult(result, maximum: 4096)
    }
    func discardUpload(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, reconciliation: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> Data {
        try plan.requireOwner(context); try reconciliation.requireOwner(context)
        guard reconciliation.id == plan.material.menu.id, reconciliation.reviewSHA256 == plan.reviewSHA256,
              reconciliation.excludedMenuID == plan.material.menu.id else { throw SNESLibraryInventory.failure() }
        let result = try await client.readSNESLibraryDiscardUpload(context, plan: plan, reconciliation: reconciliation, challenge: challenge)
        try plan.requireOwner(context); try reconciliation.requireOwner(context)
        return try checkedResult(result, maximum: 2048)
    }
    func discardPreview(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan,
                        reconciliation: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> Data {
        try plan.requireOwner(context); try scope.validateSources(); try reconciliation.requireOwner(context)
        guard reconciliation.id == plan.material.menu.id, reconciliation.reviewSHA256 == plan.reviewSHA256, reconciliation.excludedMenuID == plan.material.menu.id else { throw SNESLibraryInventory.failure() }
        let nonce = UUID(), raw: Data
        raw = try await recoveryInventory(context: context, permit: reconciliation, challenge: nonce)
        try plan.requireOwner(context); try scope.validateSources(); try reconciliation.requireOwner(context)
        let fresh = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: context.sha256, hwid: context.installation.expected.hwid,
            catalogSHA256: context.installation.catalogContentSHA256, excludingIncompleteMenu: reconciliation.excludedMenuID)
        guard !fresh.incompleteNamespace || reconciliation.allowsIncompleteNamespace == true else { throw SNESLibraryInventory.failure() }
        try scope.requireCurrent(plan, inventory: fresh)
        let result = try await client.previewSNESLibraryDiscard(context, plan: plan, scope: scope, challenge: challenge)
        try plan.requireOwner(context); try scope.validateSources(); try reconciliation.requireOwner(context)
        return try checkedResult(result, maximum: 2 * 1024 * 1024)
    }
    func discardLibraryCopy(context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan,
                                preview: SNESLibraryCleanupObservation, permit: SNESLibraryDiscardPermit) async throws -> Data {
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        guard permit.attachment == context.attachment else { throw SNESLibraryInventory.failure() }
        let nonce = UUID(), freshRaw = try await discardPreview(context: context, plan: plan, scope: scope, reconciliation: permit.reconciliation, challenge: nonce)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        let fresh = try SNESLibraryCleanupObservation(freshRaw, scope: scope, challenge: nonce, contextSHA256: context.sha256)
        guard fresh.tokensSHA256 == preview.tokensSHA256, fresh.device == preview.device,
              try RecoveryProbeUSBRegistry.inventory() == [context.attachment] else { throw SNESLibraryInventory.failure() }
        let result = try await client.discardSNESLibraryCopy(context, plan: plan, scope: scope, preview: preview, permit: permit)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        return try checkedResult(result, maximum: 4096)
    }
    private func checkedResult(_ result: SSHResult, maximum: Int) throws -> Data {
        if result.exitCode == 83 { throw RecoveryProbeError.refused("Return to the SNES game-selection menu. In Options, turn off My Game Play Demo and Classic Demo, then refresh this review.") }
        if result.exitCode == 84 { throw RecoveryProbeError.refused("Open Console Setup to update the SNES before syncing this library.") }
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData.count <= maximum else { throw SNESLibraryInventory.failure() }
        return result.stdoutData
    }
    func disconnect() async { await client.disconnect() }
    struct Connection: Sendable { let session: SNESLibraryConnectionSession, context: SNESLibraryContext }
    static func connect(attachment: RecoveryProbeUSBDevice, sessionID: UUID, workspace: WorkspacePaths,
                        readOnlyOwnerIndex: Bool = false, progress: ConsoleConnectionProgressSink = { _ in }) async throws -> Connection {
        let session = SNESLibraryConnectionSession(attachment: attachment, io: Self(attachment: attachment))
        let context = try await session.connect(sessionID: sessionID, progress: progress) { hwid, version in
            let root = try readOnlyOwnerIndex ? SNESLibraryInstallationIndex.existingPrivateRoot(SNESLibraryInstallationIndex.defaultRoot()) : SNESLibraryInstallationIndex.ensureRoot()
            let journals = try SNESFirmwareJournalPolicy.root()
            let existing = try SNESLibraryInstallationIndex.load(hwid: hwid, root: root)
            if readOnlyOwnerIndex && existing == nil {throw SNESLibraryInstallation.failure()}
            let recovery = try await PayloadService.shared.pinnedRecoveryInputs()
            let selected = try await SNESLibraryOwnerSelection.choose(cached: existing?.reference, deviceVersion: version, resolve: { reference in
                guard workspace.knownBackupRoots.contains(reference.catalog.deletingLastPathComponent()) else { throw SNESLibraryInstallation.failure() }
                let key = SNESLibraryOwnerCacheKey(reference: reference, deviceVersion: version,
                    workspaceRoot: workspace.root, backupRoots: workspace.knownBackupRoots.sorted { $0.path < $1.path },
                    journalRoot: journals)
                let installation = try await ownerCache.value(for: key, validate: { installation in
                    try installation.validate()
                    try SNESFirmwareJournal.validateSiblingHistory(root: journals, excluding: reference.operationID,
                        recoveryParent: installation.accepted.material.parentOperationID)
                }) {
                    try await SNESLibraryInstallation.resolve(reference: reference, journals: journals, recovery: recovery)
                }
                return (installation, installation.expected.deviceVersion)
            }, discover: {
                try SNESLibraryInstallationIndex.discover(hwid: hwid, deviceVersion: version, journals: journals, backups: workspace.knownBackupRoots)
            })
            try existing?.validate()
            let installation = selected.owner
            if existing?.reference != selected.reference {
                guard !readOnlyOwnerIndex else {throw SNESLibraryInstallation.failure()}
                _ = try SNESLibraryInstallationIndex.save(selected.reference, root: root)
            }
            guard let index = try SNESLibraryInstallationIndex.load(hwid: hwid, root: root) else { throw SNESLibraryInstallation.failure() }
            return .init(installation: installation, index: index)
        }
        return .init(session: session, context: context)
    }
}
