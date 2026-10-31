import Foundation
import SwiftHakchiCore

struct RecoveryAssistantReview: Decodable, Equatable, Sendable {
    let operationDirectory: String
    let reviewSHA256: String
    let phase: StockRestoreJournal.Phase
    let stockBytes: Int
    let stockSHA256: String
    let preimageBytes: Int
    let preimageSHA256: String
    var operationURL: URL { URL(fileURLWithPath:operationDirectory) }
    static func reference(at url: URL) throws -> Self {
        let directory = try RestoreDirectory(url)
        let bytes = try directory.read("plan.json",maximum:65536)
        let plan = try JSONDecoder().decode(StockRestorePlan.self,from:bytes)
        return Self(operationDirectory:url.path,reviewSHA256:BackupManifest.digest(bytes),phase:.prepared,
                    stockBytes:plan.stockBytes,stockSHA256:plan.stockSHA256,
                    preimageBytes:plan.preimageBytes,preimageSHA256:plan.preimageSHA256)
    }
}
struct LegacyRecoveryAssistantReview: Decodable, Equatable, Sendable {
    let operationDirectory: String
    let reviewSHA256: String
    let phase: LegacyBoot2ActivationJournal.Phase
    let stockBytes: Int
    let stockSHA256: String
    let legacyBytes: Int
    let legacySHA256: String
    var operationURL: URL { URL(fileURLWithPath: operationDirectory) }
    static func reference(at url: URL) throws -> Self {
        let directory = try RestoreDirectory(url)
        let bytes = try directory.read("plan.json", maximum: 65536)
        let plan = try JSONDecoder().decode(LegacyBoot2ActivationPlan.self, from: bytes)
        let material = LegacyBoot2ActivationMaterial(plan: plan,
            stock: try directory.read("stock.img"), legacy: try directory.read("legacy.img"))
        try material.validateIntegrity()
        return Self(operationDirectory: url.path, reviewSHA256: BackupManifest.digest(bytes),
                    phase: .prepared, stockBytes: plan.stockBytes, stockSHA256: plan.stockSHA256,
                    legacyBytes: plan.legacyBytes, legacySHA256: plan.legacySHA256)
    }
}
enum RecoveryAssistantAction: Sendable {
    case snapshot(URL), installEvidence(URL), prepare(snapshot:URL,stock:URL,journals:URL)
    case inspect(RecoveryAssistantReview), preflight(RecoveryAssistantReview), write(RecoveryAssistantReview), confirm(RecoveryAssistantReview)
    case legacyPrepare(snapshot:URL,stock:URL,journals:URL)
    case legacyInspect(LegacyRecoveryAssistantReview), legacyPreflight(LegacyRecoveryAssistantReview)
    case legacyWrite(LegacyRecoveryAssistantReview), legacyConfirm(LegacyRecoveryAssistantReview)
    var isHardware: Bool {
        switch self { case .snapshot,.installEvidence,.preflight,.write,.legacyPreflight,.legacyWrite: return true; default:return false }
    }
    var isWrite: Bool { if case .write = self { return true }; if case .legacyWrite = self { return true }; return false }
    var title: String {
        switch self {
        case .snapshot:return "Capture Kernel Snapshot"
        case .installEvidence:return "Capture Install Evidence — read only"
        case .prepare:return "Prepare Stock Restore"
        case .inspect:return "Review Existing Operation"
        case .preflight:return "Check Stock Restore — no flash"
        case .write:return "Restore Stock Kernel"
        case .confirm:return "Record Console Test"
        case .legacyPrepare:return "Prepare Legacy NES Connection"
        case .legacyInspect:return "Review Legacy Activation"
        case .legacyPreflight:return "Check Legacy Activation — no flash"
        case .legacyWrite:return "Restore Legacy NES Connection"
        case .legacyConfirm:return "Record Legacy Console Test"
        }
    }
}
enum RecoveryAssistantResult: Sendable {
    case snapshot(URL), review(RecoveryAssistantReview), legacyReview(LegacyRecoveryAssistantReview)
}
enum RecoveryAssistantDriver {
    static func execute(_ action: RecoveryAssistantAction, progress: @escaping RecoveryProgressSink) async throws -> RecoveryAssistantResult {
        let legacyMode: LegacyBoot2ActivationDiagnosticOptions?
        switch action {
        case .legacyPrepare(let snapshot, let stock, let journals): legacyMode = .prepare(snapshot.path, stock.path, journals.path)
        case .legacyInspect(let r): legacyMode = .inspect(r.operationDirectory, r.reviewSHA256)
        case .legacyPreflight(let r): legacyMode = .preflight(r.operationDirectory, r.reviewSHA256)
        case .legacyWrite(let r): legacyMode = .write(r.operationDirectory, r.reviewSHA256)
        case .legacyConfirm(let r): legacyMode = .confirm(r.operationDirectory, r.reviewSHA256)
        default: legacyMode = nil
        }
        if let legacyMode {
            let output = try await LegacyBoot2ActivationDiagnostic.run(mode: legacyMode,
                loadInputs: { try await PayloadService.shared.pinnedRecoveryInputs() },
                makeIO: { NativeLegacyBoot2ActivationIO() }, progress: progress)
            return .legacyReview(try JSONDecoder().decode(LegacyRecoveryAssistantReview.self, from: Data(output.utf8)))
        }
        let mode: StockRestoreDiagnosticOptions
        switch action {
        case .snapshot(let root), .installEvidence(let root):
            await progress(.checkingMaterial)
            let inputs = try await PayloadService.shared.pinnedRecoveryInputs()
            let diagnostic: RecoveryDiagnosticOptions
            if case .installEvidence = action { diagnostic = .installEvidence(root.path) }
            else { diagnostic = .snapshot(root.path) }
            let output = try await RecoveryDiagnosticRunner.run(mode:diagnostic,inputs:inputs,makeIO:{ NativeRecoveryProbeIO() },progress:progress)
            struct SnapshotResult: Decodable { let snapshotDirectory: String }
            return .snapshot(URL(fileURLWithPath:try JSONDecoder().decode(SnapshotResult.self,from:Data(output.utf8)).snapshotDirectory))
        case .prepare(let snapshot,let stock,let journals): mode = .prepare(snapshot.path,stock.path,journals.path)
        case .inspect(let r): mode = .inspect(r.operationDirectory,r.reviewSHA256)
        case .preflight(let r): mode = .preflight(r.operationDirectory,r.reviewSHA256)
        case .write(let r): mode = .write(r.operationDirectory,r.reviewSHA256)
        case .confirm(let r): mode = .confirm(r.operationDirectory,r.reviewSHA256)
        case .legacyPrepare,.legacyInspect,.legacyPreflight,.legacyWrite,.legacyConfirm: throw RestoreDirectory.failure()
        }
        let output = try await StockRestoreDiagnostic.run(mode:mode,loadInputs:{ try await PayloadService.shared.pinnedRecoveryInputs() },
                                                        makeIO:{ NativeStockRestoreIO() },progress:progress)
        return .review(try JSONDecoder().decode(RecoveryAssistantReview.self,from:Data(output.utf8)))
    }
}

@MainActor
final class RecoveryAssistantModel: ObservableObject {
    typealias Execute = @Sendable (RecoveryAssistantAction, @escaping RecoveryProgressSink) async throws -> RecoveryAssistantResult
    @Published private(set) var busy = false
    @Published private(set) var title = "NES Recovery Assistant"
    @Published private(set) var status = "Choose a recovery action to begin."
    @Published private(set) var activity = OperationActivity()
    @Published private(set) var review: RecoveryAssistantReview?
    @Published private(set) var reviewedWrite: RecoveryAssistantReview?
    @Published private(set) var legacyReview: LegacyRecoveryAssistantReview?
    @Published private(set) var reviewedLegacyWrite: LegacyRecoveryAssistantReview?
    @Published private(set) var snapshotURL: URL?
    @Published private(set) var normalBootPending = false
    @Published private(set) var requiresPreservedPower = false
    @Published private(set) var failure: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?
    let demonstration: Bool
    private let execute: Execute
    private var token = UUID()
    private var snapshotWasInstallEvidence = false
    init(demonstration: Bool = false, execute: @escaping Execute = { try await RecoveryAssistantDriver.execute($0,progress:$1) }) {
        self.execute = execute; self.demonstration = demonstration
        if demonstration {
            title = "Recovery progress demonstration"
            status = RecoveryStage.readingCurrentKernel.title
            for stage in [RecoveryStage.checkingMaterial,.checkingUSB,.uploadingRecovery,.waitingForRecovery,.checkingIdentity,.readingCurrentKernel] { activity.append(stage.title) }
            activity.append("Demonstration only — no console access or changes")
        }
    }
    var canPreflight: Bool { !busy && !normalBootPending && failure == nil && review?.phase == .prepared }
    var writeEligible: Bool { !busy && !normalBootPending && failure == nil && review?.phase == .preflightVerified }
    var canWrite: Bool { writeEligible && reviewedWrite == review }
    var canLegacyPreflight: Bool { !busy && !normalBootPending && failure == nil && legacyReview?.phase == .prepared }
    var legacyWriteEligible: Bool { !busy && !normalBootPending && failure == nil && legacyReview?.phase == .preflightVerified }
    var canWriteLegacy: Bool { legacyWriteEligible && reviewedLegacyWrite == legacyReview }
    func acknowledgeWriteReview(_ acknowledged: Bool, for value: RecoveryAssistantReview) {
        reviewedWrite = acknowledged && writeEligible && value == review ? value : nil
    }
    func acknowledgeLegacyWriteReview(_ acknowledged: Bool, for value: LegacyRecoveryAssistantReview) {
        reviewedLegacyWrite = acknowledged && legacyWriteEligible && value == legacyReview ? value : nil
    }
    func clearWriteReview() { reviewedWrite = nil; reviewedLegacyWrite = nil }
    var isReviewOnly: Bool {
        (review.map { [.burnIntent,.uncertain,.stoppedBeforeWrite,.menuAccepted].contains($0.phase) } ?? false) ||
        (legacyReview.map { [.burnIntent,.uncertain,.stoppedBeforeWrite,.menuAccepted].contains($0.phase) } ?? false)
    }

    func perform(_ action: RecoveryAssistantAction, ready: Bool = false) async {
        guard !busy, !demonstration else { return }
        if action.isHardware && (!ready || requiresPreservedPower || normalBootPending) {
            status = "Complete the console instructions and confirm readiness before starting."; return
        }
        switch action {
        case .preflight(let r): guard canPreflight, r == review else { return }
        case .write(let r): guard canWrite, r == review else { return }
        case .confirm(let r): guard normalBootPending, r == review, r.phase == .readbackVerified else { return }
        case .legacyPreflight(let r): guard canLegacyPreflight, r == legacyReview else { return }
        case .legacyWrite(let r): guard canWriteLegacy, r == legacyReview else { return }
        case .legacyConfirm(let r): guard normalBootPending, r == legacyReview, r.phase == .readbackVerified else { return }
        default: break
        }
        let id = UUID(); token = id; busy = true
        clearWriteReview()
        title = action.title; status = "Starting…"; startedAt = Date(); endedAt = nil; failure = nil
        activity = OperationActivity(); activity.append(title)
        let progress: RecoveryProgressSink = { [weak self] stage in
            await self?.receive(stage,token:id)
        }
        do {
            let result = try await execute(action,progress)
            switch result {
            case .snapshot(let url):
                review = nil; legacyReview = nil; snapshotURL = url; normalBootPending = true; requiresPreservedPower = false
                if case .installEvidence = action {
                    snapshotWasInstallEvidence = true
                    status = "Boot1 and kernel evidence saved and verified. Boot1 format is not yet validated for installation. Return the NES to normal boot using the steps below."
                } else {
                    snapshotWasInstallEvidence = false
                    status = "Kernel snapshot saved and verified. Return the NES to normal boot using the steps below."
                }
            case .review(let value):
                snapshotWasInstallEvidence = false
                review = value; legacyReview = nil
                clearWriteReview()
                requiresPreservedPower = [.burnIntent,.uncertain].contains(value.phase)
                normalBootPending = [.preflightVerified,.readbackVerified].contains(value.phase)
                switch value.phase {
                case .prepared: status = "Files verified locally. Ready for the separate no-flash check."
                case .preflightVerified: status = "No-flash check passed. Confirm normal menu return before the separate write action."
                case .readbackVerified: status = "Stock kernel readback verified. Confirm normal boot, a built-in game and controller input."
                case .menuAccepted: status = "Stock kernel restored and verified; menu, game and controller test confirmed."
                case .stoppedBeforeWrite: status = "This operation stopped before write intent. It cannot be restarted; review its files before preparing another operation."
                case .burnIntent,.uncertain: status = "Uncertain write state. Keep power and cables unchanged. Preserve this journal; do not retry or reboot."
                }
            case .legacyReview(let value):
                snapshotWasInstallEvidence = false
                legacyReview = value; review = nil
                clearWriteReview()
                requiresPreservedPower = [.burnIntent,.uncertain].contains(value.phase)
                normalBootPending = [.preflightVerified,.readbackVerified].contains(value.phase)
                switch value.phase {
                case .prepared: status = "Legacy image verified locally. Ready for a separate no-flash check."
                case .preflightVerified: status = "No-flash legacy check passed. Confirm normal menu return before the separate write action."
                case .readbackVerified: status = "Preserved legacy kernel readback verified. Confirm the menu, a built-in game and controller input."
                case .menuAccepted: status = "Legacy kernel and normal menu test verified. Reconnect Swift Hakchi before a separate game sync."
                case .stoppedBeforeWrite: status = "Legacy activation stopped before write intent. Review the journal before preparing another operation."
                case .burnIntent,.uncertain: status = "Uncertain legacy write. Keep power and cables unchanged; do not retry or reboot."
                }
            }
            activity.append(status)
        } catch {
            normalBootPending = false
            // A failed write or unreadable journal must never suggest safe reboot/retry.
            if action.isWrite { requiresPreservedPower = true }
            if case .inspect = action { requiresPreservedPower = true }
            if case .legacyInspect = action { requiresPreservedPower = true }
            failure = OperationActivity.safe(error.localizedDescription)
            status = requiresPreservedPower
                ? "Keep power and cables unchanged. Preserve the operation journal; do not retry or reboot."
                : "The operation stopped. Review the details and recovery files before another attempt."
            activity.append(failure!); activity.append(status)
        }
        endedAt = Date(); busy = false
    }
    private func receive(_ stage: RecoveryStage, token: UUID) {
        guard busy, self.token == token else { return }
        status = stage.title; activity.append(stage.title)
    }
    func confirmNormalBoot() async {
        guard normalBootPending, !busy else { return }
        if let review, review.phase == .readbackVerified {
            await perform(.confirm(review))
        } else if let legacyReview, legacyReview.phase == .readbackVerified {
            await perform(.legacyConfirm(legacyReview))
        } else {
            normalBootPending = false
            if review?.phase == .preflightVerified {
                status = "Normal menu return confirmed. A stock write is a separate action and requires entering recovery mode again."
            } else if legacyReview?.phase == .preflightVerified {
                status = "Normal menu return confirmed. A legacy boot2 write is a separate action and requires entering recovery mode again."
            } else if snapshotWasInstallEvidence {
                status = "Normal menu return confirmed. Install evidence is saved for native installer validation; it cannot prepare a stock restore."
            } else {
                status = "Normal menu return confirmed. You can prepare a restore using the new snapshot."
            }
            activity.append(status)
        }
    }
    func reportInputError(_ error: Error) {
        guard !busy else { return }
        failure = OperationActivity.safe(error.localizedDescription)
        status = "The selected files could not be verified. No console action was started."
        activity.append(failure!)
    }
}
