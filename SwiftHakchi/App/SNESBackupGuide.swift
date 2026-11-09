import Foundation

@MainActor final class SNESBackupGuide: ObservableObject {
    enum Phase { case instructions, working, returnToNormal, complete, failed, resumeWorking, resumeConfirmNormal
        case startupInstructions, startupWorking, startupReturnToNormal, startupComplete, startupFailed
        case menuSupportInstructions, menuSupportWorking, menuSupportReturnToNormal, menuSupportComplete, menuSupportFailed
        case componentsInstructions, componentsWorking, componentsReturnToNormal, componentsComplete, componentsFailed
        case dataInstructions, dataWorking, dataReturnToNormal, dataComplete, dataFailed
        case runtimeInstructions, runtimeWorking, runtimeReturnToNormal, runtimeComplete, runtimeFailed
        case candidateWorking, candidateComplete, candidateFailed
        case preflightInstructions, preflightWorking, preflightReturnToNormal, preflightComplete, preflightBackupChanged, preflightFailed
        case trialInstructions, trialWorking, trialPlaying, trialPostWorking, trialReturnToNormal, trialComplete, trialFailed
        case activeInstructions, activeWorking, activeReturnToNormal, activeComplete, activeFailed
        case freshDataInstructions, freshDataWorking, freshDataPowerOff, freshDataReturnToNormal, freshDataComplete, freshDataFailed
        case planWorking, planComplete, planFailed, normalBootNeedsHelp }
    @Published private(set) var phase = Phase.instructions
    @Published private(set) var stage = RecoveryStage.checkingMaterial
    @Published private(set) var backupDirectory: URL?
    @Published private(set) var recoveryDirectory: URL?
    @Published private(set) var recoveryError: String?
    @Published private(set) var helpersDirectory: URL?
    @Published private(set) var helpersError: String?
    @Published private(set) var preparingRecovery = false
    @Published private(set) var diagnosticDirectory: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var startupDirectory: URL?
    @Published private(set) var startupDiagnosticDirectory: URL?
    @Published private(set) var startupError: String?
    @Published private(set) var menuSupportDirectory: URL?
    @Published private(set) var menuSupportDiagnosticDirectory: URL?
    @Published private(set) var menuSupportError: String?
    @Published private(set) var componentsDirectory: URL?
    @Published private(set) var componentsDiagnosticDirectory: URL?
    @Published private(set) var componentsError: String?
    @Published private(set) var dataDirectory: URL?
    @Published private(set) var dataDiagnosticDirectory: URL?
    private var dataReceipt: SNESDataSnapshotReceipt?
    @Published private(set) var dataError: String?
    @Published private(set) var dataDetail = "Preparing the backup"
    @Published private(set) var runtimeDirectory: URL?
    @Published private(set) var runtimeError: String?
    @Published private(set) var candidateDirectory: URL?
    @Published private(set) var candidateError: String?
    @Published private(set) var preflightDirectory: URL?
    @Published private(set) var preflightError: String?
    @Published private(set) var preflightBackupMatches: Bool?
    @Published private(set) var trialError: String?
    @Published private(set) var trialDiagnosticDirectory: URL?
    @Published private(set) var trialStartedDirectory: URL?
    @Published private(set) var trialPlayedDirectory: URL?
    @Published private(set) var activeDirectory: URL?
    @Published private(set) var activeError: String?
    @Published private(set) var activeDiagnosticDirectory: URL?
    @Published private(set) var freshDataDirectory: URL?
    @Published private(set) var freshDataDiagnosticDirectory: URL?
    @Published private(set) var freshDataError: String?
    private var freshDataReceipt: SNESDataSnapshotReceipt?
    @Published private(set) var firmwarePlan: SNESFirmwarePreparationReceipt?
    @Published private(set) var planError: String?
    @Published private(set) var resumeUnverifiedCount = 0
    private var resumedStage: SNESSetupResumeEvidence.Stage?
    private var resumedEvidence: SNESSetupResumeEvidence?
    private var resumeID: UUID?
    private var backupReceipt: SNESSetupRecordReceipt?
    private var startupReceipt: SNESSetupRecordReceipt?
    private var menuSupportReceipt: SNESSetupRecordReceipt?
    private var componentsReceipt: SNESSetupRecordReceipt?
    private var runtimeReceipt: SNESSetupRecordReceipt?
    private var candidateReceipt: SNESSetupRecordReceipt?
    private var preflightReceipt: SNESStartupPreflightReceipt?
    private var trialStartedReceipt: SNESSetupRecordReceipt?
    private var trialPlayedReceipt: SNESSetupRecordReceipt?
    private var activeReceipt: SNESSetupRecordReceipt?
    private let execute: @Sendable (@escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt
    private let prepareRecovery: (@Sendable (SNESSetupRecordReceipt) async throws -> URL)?
    private let prepareHelpers: (@Sendable () async throws -> URL)?
    private let prepareStartup: (@Sendable (SNESSetupRecordReceipt, URL, URL, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)?
    private let captureMenuSupport: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)?
    private let captureComponents: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)?
    private let captureData: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordChain, @escaping RecoveryProgressSink, @escaping @Sendable (String) async -> Void) async throws -> SNESDataSnapshotReceipt)?
    private let captureRuntime: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordChain, SNESDataSnapshotReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)?
    private let prepareCandidate: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordChain, SNESDataSnapshotReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)?
    private let preflight: (@Sendable (SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESStartupPreflightReceipt)?
    private let startTrialOperation: (@Sendable (SNESSetupRecordReceipt, SNESStartupPreflightReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)?
    private let checkTrialOperation: (@Sendable (SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)?
    private let captureActive: (@Sendable (SNESSetupRecordReceipt, URL, SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)?
    private let prepareFirmwarePlan: (@Sendable (SNESSetupRecordReceipt, URL, SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt, SNESDataSnapshotReceipt) async throws -> SNESFirmwarePreparationReceipt)?
    private let validateResume: @Sendable (SNESSetupResumeEvidence) async throws -> Void
    init(execute: @escaping @Sendable (@escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         prepareRecovery: (@Sendable (SNESSetupRecordReceipt) async throws -> URL)? = nil,
         prepareHelpers: (@Sendable () async throws -> URL)? = nil,
         prepareStartup: (@Sendable (SNESSetupRecordReceipt, URL, URL, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)? = nil,
         captureMenuSupport: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)? = nil,
         captureComponents: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)? = nil,
         captureData: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordChain, @escaping RecoveryProgressSink, @escaping @Sendable (String) async -> Void) async throws -> SNESDataSnapshotReceipt)? = nil,
         captureRuntime: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordChain, SNESDataSnapshotReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)? = nil,
         prepareCandidate: (@Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordChain, SNESDataSnapshotReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)? = nil,
         preflight: (@Sendable (SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESStartupPreflightReceipt)? = nil,
         startTrial: (@Sendable (SNESSetupRecordReceipt, SNESStartupPreflightReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)? = nil,
         checkTrial: (@Sendable (SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)? = nil,
         captureActive: (@Sendable (SNESSetupRecordReceipt, URL, SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt)? = nil,
         prepareFirmwarePlan: (@Sendable (SNESSetupRecordReceipt, URL, SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt, SNESDataSnapshotReceipt) async throws -> SNESFirmwarePreparationReceipt)? = nil,
         validateResume: @escaping @Sendable (SNESSetupResumeEvidence) async throws -> Void = { evidence in
             try await AppState.runSNESRecoveryWorker { try evidence.revalidate() }
         }) {
        self.execute = execute
        self.prepareRecovery = prepareRecovery
        self.prepareHelpers = prepareHelpers
        self.prepareStartup = prepareStartup
        self.captureMenuSupport = captureMenuSupport
        self.captureComponents = captureComponents
        self.captureData = captureData
        self.captureRuntime = captureRuntime
        self.prepareCandidate = prepareCandidate
        self.preflight = preflight
        self.startTrialOperation = startTrial; self.checkTrialOperation = checkTrial
        self.captureActive = captureActive
        self.prepareFirmwarePlan = prepareFirmwarePlan
        self.validateResume = validateResume
    }
    func start(ready: Bool) async {
        guard ready, phase == .instructions else { return }
        phase = .working
        do {
            let backup = try await execute { [weak self] stage in await self?.update(stage) }
            try require(backup, kind: .backup)
            backupReceipt = backup; backupDirectory = backup.directory
            if let prepareRecovery {
                preparingRecovery = true
                do { recoveryDirectory = try await prepareRecovery(backup) }
                catch { recoveryError = error.localizedDescription }
                preparingRecovery = false
            }
            if let prepareHelpers {
                preparingRecovery = true
                do { helpersDirectory = try await prepareHelpers() }
                catch { helpersError = error.localizedDescription }
                preparingRecovery = false
            }
        } catch {
            errorMessage = error.localizedDescription
            diagnosticDirectory = (error as? SNESSetupDiagnosticSavedError)?.directory
        }
        // Even a failed boot request may have executed. Never retry or claim normal mode automatically.
        phase = .returnToNormal
    }
    private func update(_ value: RecoveryStage) { stage = value }
    func resume(_ evidence: SNESSetupResumeEvidence, unverifiedCount: Int) async throws {
        guard phase == .instructions, unverifiedCount >= 0 else { throw SNESOfflineSource.failure() }
        let id = UUID()
        resumeID = id
        phase = .resumeWorking
        do {
            try await validateResume(evidence)
            try Task.checkCancellation()
            guard resumeID == id, phase == .resumeWorking else { throw CancellationError() }
            backupDirectory = evidence.backup; recoveryDirectory = evidence.recovery; helpersDirectory = evidence.helpers
            backupReceipt = evidence.receipt(for: .backup)
            startupDirectory = evidence.startup; menuSupportDirectory = evidence.support; componentsDirectory = evidence.components
            startupReceipt = evidence.receipt(for: .startup); menuSupportReceipt = evidence.receipt(for: .menuSupport)
            componentsReceipt = evidence.receipt(for: .components)
            resumeUnverifiedCount = unverifiedCount; resumedStage = evidence.stage; resumedEvidence = evidence
            resumeID = nil
            phase = .resumeConfirmNormal
        } catch {
            if resumeID == id {
                resumeID = nil
                phase = .instructions
            }
            throw error
        }
    }
    func cancelResume() {
        guard phase == .resumeWorking || phase == .resumeConfirmNormal else { return }
        resumeID = nil
        backupDirectory = nil; recoveryDirectory = nil; helpersDirectory = nil; backupReceipt = nil
        startupDirectory = nil; menuSupportDirectory = nil; componentsDirectory = nil
        startupReceipt = nil; menuSupportReceipt = nil; componentsReceipt = nil
        resumedStage = nil; resumedEvidence = nil; resumeUnverifiedCount = 0
        phase = .instructions
    }
    private func revalidateResumedEvidence() async throws {
        if let resumedEvidence {
            try await AppState.runSNESRecoveryWorker { try resumedEvidence.revalidate() }
        }
    }
    private func require(_ receipt: SNESSetupRecordReceipt, kind: SNESSetupRecordReceipt.Kind) throws {
        guard receipt.kind == kind, receipt.directory.isFileURL, receipt.manifestSHA256.count == 64,
              SNESRuntimeBinding.hex(receipt.manifestSHA256) else { throw SNESRuntimeBinding.failure() }
    }
    func confirmResumedNormalBoot() {
        guard phase == .resumeConfirmNormal, let resumedStage else { return }
        switch resumedStage {
        case .backup: phase = .complete
        case .startup: phase = .startupComplete
        case .menuSupport: phase = .menuSupportComplete
        case .components: phase = .componentsComplete
        }
    }
    func confirmNormalBoot() {
        guard phase == .returnToNormal else { return }
        phase = errorMessage == nil ? .complete : .failed
    }
    var canReviewStartupCheck: Bool {
        phase == .complete && backupReceipt != nil && recoveryDirectory != nil && helpersDirectory != nil && prepareStartup != nil
    }
    func reviewStartupCheck() {
        guard canReviewStartupCheck else { return }
        phase = .startupInstructions
    }
    func cancelStartupCheck() {
        guard phase == .startupInstructions else { return }
        phase = .complete
    }
    func startStartupCheck(ready: Bool) async {
        guard ready, phase == .startupInstructions, let backupReceipt, let recoveryDirectory,
              let helpersDirectory, let prepareStartup else { return }
        phase = .startupWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await prepareStartup(backupReceipt, recoveryDirectory, helpersDirectory) {
                    [weak self] stage in await self?.update(stage)
                }
            }
            try require(receipt, kind: .startup)
            startupDirectory = receipt.directory
            if let resumedEvidence {
                self.resumedEvidence = try await AppState.runSNESRecoveryWorker { try resumedEvidence.advancing(receipt) }
            }
            startupReceipt = receipt
        } catch {
            startupError = error.localizedDescription
            startupDiagnosticDirectory = (error as? SNESPreparationDiagnosticSavedError)?.directory
        }
        // A failed request can still have booted temporary software.
        phase = .startupReturnToNormal
    }
    func confirmStartupNormalBoot() {
        guard phase == .startupReturnToNormal else { return }
        phase = startupError == nil ? .startupComplete : .startupFailed
    }
    func reportNormalBootProblem() {
        guard phase == .instructions || phase == .returnToNormal || phase == .startupReturnToNormal || phase == .menuSupportReturnToNormal || phase == .componentsReturnToNormal || phase == .dataReturnToNormal || phase == .runtimeReturnToNormal || phase == .preflightReturnToNormal || phase == .trialReturnToNormal || phase == .activeReturnToNormal || phase == .freshDataReturnToNormal || phase == .resumeConfirmNormal else { return }
        phase = .normalBootNeedsHelp
    }
    var canReviewMenuSupport: Bool {
        phase == .startupComplete && backupReceipt != nil && recoveryDirectory != nil && helpersDirectory != nil && startupReceipt != nil && captureMenuSupport != nil
    }
    func reviewMenuSupport() { guard canReviewMenuSupport else { return }; phase = .menuSupportInstructions }
    func cancelMenuSupport() { guard phase == .menuSupportInstructions else { return }; phase = .startupComplete }
    func startMenuSupport(ready: Bool) async {
        guard ready, phase == .menuSupportInstructions, let backupReceipt, let recoveryDirectory,
              let helpersDirectory, let startupReceipt, let captureMenuSupport else { return }
        phase = .menuSupportWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await captureMenuSupport(backupReceipt, recoveryDirectory, helpersDirectory, startupReceipt) {
                    [weak self] stage in await self?.update(stage)
                }
            }
            try require(receipt, kind: .menuSupport)
            menuSupportDirectory = receipt.directory
            if let resumedEvidence {
                self.resumedEvidence = try await AppState.runSNESRecoveryWorker { try resumedEvidence.advancing(receipt) }
            }
            menuSupportReceipt = receipt
        } catch {
            menuSupportError = error.localizedDescription
            menuSupportDiagnosticDirectory = (error as? SNESPreparationDiagnosticSavedError)?.directory
        }
        phase = .menuSupportReturnToNormal
    }
    func confirmMenuSupportNormalBoot() {
        guard phase == .menuSupportReturnToNormal else { return }
        phase = menuSupportError == nil ? .menuSupportComplete : .menuSupportFailed
    }
    var canReviewComponents: Bool {
        phase == .menuSupportComplete && backupReceipt != nil && recoveryDirectory != nil && helpersDirectory != nil && startupReceipt != nil && menuSupportReceipt != nil && captureComponents != nil
    }
    func reviewComponents() { guard canReviewComponents else { return }; phase = .componentsInstructions }
    func cancelComponents() { guard phase == .componentsInstructions else { return }; phase = .menuSupportComplete }
    func startComponents(ready: Bool) async {
        guard ready, phase == .componentsInstructions, let backupReceipt, let recoveryDirectory, let helpersDirectory,
              let startupReceipt, let menuSupportReceipt, let captureComponents else { return }
        phase = .componentsWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await captureComponents(backupReceipt, recoveryDirectory, helpersDirectory, startupReceipt, menuSupportReceipt) {
                    [weak self] stage in await self?.update(stage)
                }
            }
            try require(receipt, kind: .components)
            componentsDirectory = receipt.directory
            if let resumedEvidence {
                self.resumedEvidence = try await AppState.runSNESRecoveryWorker { try resumedEvidence.advancing(receipt) }
            }
            componentsReceipt = receipt
        } catch {
            componentsError = error.localizedDescription
            componentsDiagnosticDirectory = (error as? SNESPreparationDiagnosticSavedError)?.directory
        }
        phase = .componentsReturnToNormal
    }
    func confirmComponentsNormalBoot() {
        guard phase == .componentsReturnToNormal else { return }
        phase = componentsError == nil ? .componentsComplete : .componentsFailed
    }
    var canReviewDataBackup: Bool {
        phase == .componentsComplete && backupReceipt != nil && recoveryDirectory != nil && helpersDirectory != nil && recordChain != nil && captureData != nil
    }
    private var recordChain: SNESSetupRecordChain? {
        guard let startupReceipt, let menuSupportReceipt, let componentsReceipt else { return nil }
        return SNESSetupRecordChain(startup: startupReceipt, support: menuSupportReceipt, components: componentsReceipt)
    }
    func reviewDataBackup() {
        if phase == .dataFailed {
            guard backupReceipt != nil, recoveryDirectory != nil, helpersDirectory != nil, recordChain != nil, captureData != nil else { return }
            dataError = nil
            phase = .dataInstructions
            return
        }
        if phase == .preflightBackupChanged {
            guard backupReceipt != nil, recoveryDirectory != nil, helpersDirectory != nil, recordChain != nil, captureData != nil else { return }
            // Keep all saved files; later steps must use the replacement backup.
            dataReceipt = nil; dataDirectory = nil; dataError = nil; dataDiagnosticDirectory = nil
            runtimeReceipt = nil; runtimeDirectory = nil; runtimeError = nil
            candidateReceipt = nil; candidateDirectory = nil; candidateError = nil
            preflightReceipt = nil; preflightDirectory = nil; preflightError = nil; preflightBackupMatches = nil
            phase = .dataInstructions
            return
        }
        guard canReviewDataBackup else { return }
        phase = .dataInstructions
    }
    func cancelDataBackup() { guard phase == .dataInstructions else { return }; phase = .componentsComplete }
    func startDataBackup(ready: Bool) async {
        guard ready, phase == .dataInstructions, let backupReceipt, let recoveryDirectory,
              let helpersDirectory, let recordChain, let captureData else { return }
        phase = .dataWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await captureData(backupReceipt, recoveryDirectory, helpersDirectory, recordChain,
                    { [weak self] stage in await self?.update(stage) },
                    { [weak self] detail in await self?.updateDataDetail(detail) })
            }
            dataReceipt = receipt; dataDirectory = receipt.directory
        } catch {
            dataError = error.localizedDescription
            if let failure = error as? SNESDataSnapshotPostSaveError, failure.backupVerified { dataDiagnosticDirectory = failure.location }
        }
        phase = .dataReturnToNormal
    }
    private func updateDataDetail(_ detail: String) { dataDetail = detail }
    /// Copy the already checked full-data backup; never contact a console.
    func copyFullDataBackup(to destination: URL, updated: Bool) async throws -> URL {
        guard let setup = backupReceipt, setup.kind == .backup,
              let receipt = updated ? freshDataReceipt : dataReceipt else { throw SNESDataSnapshotError.refused }
        return try await Task.detached {
            let original = try SNESOfflineSource.load(snapshot: setup.directory)
            guard original.manifestSHA256 == setup.manifestSHA256 else { throw SNESDataSnapshotError.refused }
            let source = try SNESPreparationSource.load(original)
            let checked = try SNESDataSnapshotPackage.load(receipt: receipt, source: source)
            return try SNESPortableDataSnapshot.copy(checked, to: destination)
        }.value
    }
    func confirmDataNormalBoot() {
        guard phase == .dataReturnToNormal else { return }
        phase = dataError == nil ? .dataComplete : .dataFailed
    }
    var canReviewRuntime: Bool {
        phase == .dataComplete && backupReceipt != nil && recoveryDirectory != nil && helpersDirectory != nil && recordChain != nil && dataReceipt != nil && captureRuntime != nil
    }
    func reviewRuntime() { guard canReviewRuntime else { return }; phase = .runtimeInstructions }
    func cancelRuntime() { guard phase == .runtimeInstructions else { return }; phase = .dataComplete }
    func startRuntime(ready: Bool) async {
        guard ready, phase == .runtimeInstructions, let backupReceipt, let recoveryDirectory,
              let helpersDirectory, let recordChain, let dataReceipt, let captureRuntime else { return }
        phase = .runtimeWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await captureRuntime(backupReceipt, recoveryDirectory, helpersDirectory, recordChain, dataReceipt) {
                    [weak self] stage in await self?.update(stage)
                }
            }
            try require(receipt, kind: .runtime)
            runtimeReceipt = receipt; runtimeDirectory = receipt.directory
        } catch { runtimeError = error.localizedDescription }
        phase = .runtimeReturnToNormal
    }
    func confirmRuntimeNormalBoot() {
        guard phase == .runtimeReturnToNormal else { return }
        phase = runtimeError == nil ? .runtimeComplete : .runtimeFailed
    }
    var canPrepareCandidate: Bool {
        phase == .runtimeComplete && backupReceipt != nil && recoveryDirectory != nil && helpersDirectory != nil && recordChain != nil && dataReceipt != nil && runtimeReceipt != nil && prepareCandidate != nil
    }
    func retryCandidate() {
        guard phase == .candidateFailed else { return }
        candidateError = nil
        phase = .runtimeComplete
    }
    func startCandidate() async {
        guard canPrepareCandidate, let backupReceipt, let recoveryDirectory, let helpersDirectory,
              let recordChain, let dataReceipt, let runtimeReceipt, let prepareCandidate else { return }
        phase = .candidateWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await prepareCandidate(backupReceipt, recoveryDirectory, helpersDirectory, recordChain, dataReceipt, runtimeReceipt) {
                    [weak self] stage in await self?.update(stage)
                }
            }
            try require(receipt, kind: .candidate)
            candidateReceipt = receipt; candidateDirectory = receipt.directory
            phase = .candidateComplete
        } catch {
            candidateError = error.localizedDescription
            phase = .candidateFailed
        }
    }
    var canReviewPreflight: Bool { phase == .candidateComplete && candidateReceipt != nil && preflight != nil }
    func reviewPreflight() { guard canReviewPreflight else { return }; phase = .preflightInstructions }
    func cancelPreflight() { guard phase == .preflightInstructions else { return }; phase = .candidateComplete }
    func startPreflight(ready: Bool) async {
        guard ready, phase == .preflightInstructions, let candidateReceipt, let preflight else { return }
        phase = .preflightWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await preflight(candidateReceipt) { [weak self] stage in await self?.update(stage) }
            }
            try require(receipt.record, kind: .preflight)
            preflightReceipt = receipt; preflightDirectory = receipt.record.directory; preflightBackupMatches = receipt.backupMatches
        } catch { preflightError = error.localizedDescription }
        // The console may have booted even if the request failed.
        phase = .preflightReturnToNormal
    }
    func confirmPreflightNormalBoot() {
        guard phase == .preflightReturnToNormal else { return }
        phase = preflightError != nil ? .preflightFailed : (preflightBackupMatches == true ? .preflightComplete : .preflightBackupChanged)
    }
    func retryPreflight() {
        guard phase == .preflightFailed else { return }
        preflightError = nil; preflightBackupMatches = nil; preflightReceipt = nil; preflightDirectory = nil
        phase = .candidateComplete
    }
    var canReviewTrial: Bool {
        phase == .preflightComplete && candidateReceipt != nil && preflightReceipt?.backupMatches == true && startTrialOperation != nil && checkTrialOperation != nil
    }
    func reviewTrial() { guard canReviewTrial else { return }; phase = .trialInstructions }
    func cancelTrial() { guard phase == .trialInstructions else { return }; phase = .preflightComplete }
    func startTrial(ready: Bool) async {
        guard ready, phase == .trialInstructions, let candidateReceipt, let preflightReceipt,
              preflightReceipt.backupMatches, let startTrialOperation else { return }
        phase = .trialWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await startTrialOperation(candidateReceipt, preflightReceipt) { [weak self] stage in await self?.update(stage) }
            }
            try require(receipt, kind: .trialStarted)
            trialStartedReceipt = receipt; trialStartedDirectory = receipt.directory; phase = .trialPlaying
        } catch {
            trialError = error.localizedDescription
            trialDiagnosticDirectory = (error as? SNESPreparationDiagnosticSavedError)?.directory
            phase = .trialReturnToNormal
        }
    }
    func checkTrial(gameWorks: Bool) async {
        guard phase == .trialPlaying else { return }
        guard gameWorks else {
            trialError = "The temporary menu or game did not work. No firmware was installed."
            phase = .trialReturnToNormal; return
        }
        guard let candidateReceipt, let preflightReceipt, let trialStartedReceipt, let checkTrialOperation else {
            trialError = "The startup check could not be verified. No firmware was installed."
            phase = .trialReturnToNormal; return
        }
        phase = .trialPostWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await checkTrialOperation(candidateReceipt, preflightReceipt, trialStartedReceipt) { [weak self] stage in await self?.update(stage) }
            }
            try require(receipt, kind: .trialPlayed)
            trialPlayedReceipt = receipt; trialPlayedDirectory = receipt.directory
        } catch {
            trialError = error.localizedDescription
            trialDiagnosticDirectory = (error as? SNESPreparationDiagnosticSavedError)?.directory
        }
        phase = .trialReturnToNormal
    }
    func confirmTrialNormalBoot() {
        guard phase == .trialReturnToNormal else { return }
        phase = trialError == nil && trialPlayedReceipt != nil ? .trialComplete : .trialFailed
    }
    var canReviewActiveBackup: Bool {
        phase == .trialComplete && backupReceipt != nil && helpersDirectory != nil && candidateReceipt != nil && preflightReceipt?.backupMatches == true && trialStartedReceipt != nil && trialPlayedReceipt != nil && captureActive != nil
    }
    func reviewActiveBackup() { guard canReviewActiveBackup else { return }; phase = .activeInstructions }
    func cancelActiveBackup() { guard phase == .activeInstructions else { return }; phase = .trialComplete }
    func startActiveBackup(ready: Bool) async {
        guard ready, phase == .activeInstructions, let backupReceipt, let helpersDirectory, let candidateReceipt,
              let preflightReceipt, preflightReceipt.backupMatches, let trialStartedReceipt, let trialPlayedReceipt, let captureActive else { return }
        phase = .activeWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await captureActive(backupReceipt, helpersDirectory, candidateReceipt, preflightReceipt, trialStartedReceipt, trialPlayedReceipt) {
                    [weak self] stage in await self?.update(stage)
                }
            }
            try require(receipt, kind: .activeBoot2)
            activeReceipt = receipt; activeDirectory = receipt.directory
        } catch {
            activeError = error.localizedDescription
            if let directory = (error as? SNESPreparationDiagnosticSavedError)?.directory { activeDiagnosticDirectory = directory }
        }
        phase = .activeReturnToNormal
    }
    func confirmActiveNormalBoot() {
        guard phase == .activeReturnToNormal else { return }
        phase = activeError == nil && activeReceipt != nil ? .activeComplete : .activeFailed
    }
    func retryActiveBackup() {
        guard phase == .activeFailed else { return }
        activeError = nil; activeReceipt = nil; activeDirectory = nil
        phase = .trialComplete
    }
    var canReviewFreshDataBackup: Bool {
        (phase == .activeComplete || phase == .freshDataComplete) && backupReceipt != nil && recoveryDirectory != nil && helpersDirectory != nil && recordChain != nil && captureData != nil
    }
    func reviewFreshDataBackup() { guard canReviewFreshDataBackup else { return }; phase = .freshDataInstructions }
    func cancelFreshDataBackup() { guard phase == .freshDataInstructions else { return }; phase = freshDataReceipt == nil ? .activeComplete : .freshDataComplete }
    func startFreshDataBackup(ready: Bool) async {
        guard ready, phase == .freshDataInstructions, let backupReceipt, let recoveryDirectory,
              let helpersDirectory, let recordChain, let captureData else { return }
        freshDataError = nil; dataDetail = "Preparing the backup"
        phase = .freshDataWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await captureData(backupReceipt, recoveryDirectory, helpersDirectory, recordChain,
                    { [weak self] stage in await self?.update(stage) },
                    { [weak self] detail in await self?.updateDataDetail(detail) })
            }
            freshDataReceipt = receipt; freshDataDirectory = receipt.directory
        } catch {
            freshDataError = error.localizedDescription
            if let failure = error as? SNESDataSnapshotPostSaveError, failure.backupVerified { freshDataDiagnosticDirectory = failure.location }
        }
        // The temporary recovery environment may have started, even if saving failed.
        phase = .freshDataPowerOff
    }
    func confirmFreshDataPowerOff() {
        guard phase == .freshDataPowerOff else { return }
        phase = freshDataError == nil && freshDataReceipt != nil ? .freshDataComplete : .freshDataReturnToNormal
    }
    func confirmFreshDataNormalBoot() { guard phase == .freshDataReturnToNormal else { return }; phase = .freshDataFailed }
    func retryFreshDataBackup() {
        guard phase == .freshDataFailed else { return }
        freshDataError = nil; phase = .freshDataInstructions
    }
    var canPreparePlan: Bool {
        (phase == .activeComplete || phase == .freshDataComplete) && backupReceipt != nil && helpersDirectory != nil && candidateReceipt != nil && preflightReceipt?.backupMatches == true && trialStartedReceipt != nil && trialPlayedReceipt != nil && activeReceipt != nil && (freshDataReceipt ?? dataReceipt) != nil && prepareFirmwarePlan != nil
    }
    func retryPlan() { guard phase == .planFailed else { return }; planError = nil; phase = freshDataReceipt == nil ? .activeComplete : .freshDataComplete }
    func preparePlan() async {
        guard canPreparePlan, let backupReceipt, let helpersDirectory, let candidateReceipt, let preflightReceipt,
              preflightReceipt.backupMatches, let trialStartedReceipt, let trialPlayedReceipt, let activeReceipt,
              let dataReceipt = freshDataReceipt ?? self.dataReceipt, let prepareFirmwarePlan else { return }
        phase = .planWorking
        do {
            try await revalidateResumedEvidence()
            let receipt = try await SNESSetupSelectedBinding.$current.withValue(resumedEvidence) {
                try await prepareFirmwarePlan(backupReceipt, helpersDirectory, candidateReceipt, preflightReceipt, trialStartedReceipt, trialPlayedReceipt, activeReceipt, dataReceipt)
            }
            guard receipt.offlineReviewSHA256.count == 64, SNESRuntimeBinding.hex(receipt.offlineReviewSHA256),
                  (1...56).contains(receipt.changedUnits),
                  receipt.savedReview.map({ $0.sha256 == receipt.offlineReviewSHA256 && $0.directory.isFileURL }) ?? true else { throw SNESRuntimeBinding.failure() }
            firmwarePlan = receipt; phase = .planComplete
        } catch {
            planError = error.localizedDescription
            phase = .planFailed
        }
    }
}
