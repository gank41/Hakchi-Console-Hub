import SwiftUI
import AppKit
import Combine
import os
import UniformTypeIdentifiers
import SwiftHakchiCore

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "AppState")

/// Flash/task operation types
enum FlashOperation: Equatable {
    case installHakchi
    case uninstallHakchi
    case factoryReset
    case memboot
    case membootOriginal
    case dumpStockKernel
    case processHmods

    /// Whether this operation requires the console to be in FEL mode
    var requiresFEL: Bool {
        switch self {
        case .installHakchi, .uninstallHakchi, .factoryReset, .memboot:
            return true
        default:
            return false
        }
    }
}

/// Errors during game download from console
enum DownloadError: LocalizedError {
    case notFound(String)
    case noFiles(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let code): return "Could not find game \(code) on the console."
        case .noFiles(let code): return "No downloadable files found for \(code)."
        }
    }
}

/// Global application state, shared across the app via @EnvironmentObject
@MainActor
final class AppState: ObservableObject {
    // MARK: - Services
    let deviceManager: DeviceManager
    let gameManager: GameManagerService
    private let connectionConfig: AppConfig
    private let saveConnectionConfiguration: () -> Void
    private let checkRecoveryHost: @Sendable () async throws -> Void
    private let firmwareJournalRoot: @Sendable () throws -> URL
    private let makeSNESFirmwareIO: @Sendable (SNESFirmwareMaterial, SNESFirmwareGuard) throws -> any SNESFirmwareIO
    private let makeSNESInstalledStartupIO: @Sendable (PreparedSNESStartupTrial) throws -> any SNESInstalledStartupIO
    private let makeSNESMenuStartupPreflightIO: @Sendable (SNESStartupAdapterCandidate, SNESMenuStartupParent) throws -> any SNESStartupPreflightIO
    private let makeSNESPreparationIO: @Sendable (SNESPreparationSource) -> any SNESPreparationIO
    private let makeSNESMenuSupportIO: @Sendable (SNESMenuSupportSource) -> any SNESMenuSupportIO
    private let makeSNESOriginalComponentIO: @Sendable (SNESOriginalComponentSource) -> any SNESOriginalComponentIO
    private let makeSNESDataSnapshotIO: @Sendable (SNESPreparationSource) -> any SNESDataSnapshotIO
    private let makeSNESRuntimeIO: @Sendable () -> any RecoveryProbeIO
    private let makeSNESStartupPreflightIO: @Sendable (SNESStartupAdapterCandidate) throws -> any SNESStartupPreflightIO
    private let makeSNESStartupTrialIO: @Sendable (PreparedSNESStartupTrial) throws -> any SNESStartupTrialIO
    private let makeSNESActiveBoot2IO: @Sendable (SNESPreparationSource, SNESBoundedReadHelper) -> any SNESActiveBoot2IO
    let taskRunner = TaskRunner()
    let payloads = PayloadService.shared
    let syncTransactions = SyncTransactionService()
    let legacyChanges = LegacyGameChangeService()
    @Published var showLegacyChange = false
    @Published var showLegacySyncTrial = false
    @Published var showLegacyFullSync = false
    @Published var showSNESLibrarySync = false
    @Published private(set) var snesLibraryOriginalsOnly = false
    private var returnOriginalsAfterClosing = false
    @Published var showLegacyArchiveReclaim = false
    var legacyChangeGame: Game?
    var legacyChangeWorkspace: WorkspacePaths?
    var legacyChangeSession: UUID?

    func reviewLegacySyncTrial() {
        guard deviceManager.consoleType == .nes, deviceManager.legacyReport != nil, deviceManager.legacyClient != nil, !taskRunner.isRunning,
              !isPreparingSync, !gameManager.isLoading else { return }
        isPreparingSync = true
        showLegacySyncTrial = true
    }

    /// Opening a review grants no console mutation permission. The chosen workflow verifies its own live context.
    var canReviewLibrarySync: Bool {
        guard deviceManager.isConnected, !taskRunner.isRunning, !isPreparingSync, !gameManager.isLoading else { return false }
        switch deviceManager.consoleType {
        case .nes: return deviceManager.legacyReport != nil && deviceManager.legacyClient != nil
        case .snesUsa: return deviceManager.nativeSNESContext != nil && deviceManager.nativeSNES != nil
        default: return false
        }
    }
    func reviewLibrarySync() {
        guard canReviewLibrarySync else { return }
        isPreparingSync = true
        if deviceManager.consoleType == .snesUsa { snesLibraryOriginalsOnly = false; showSNESLibrarySync = true }
        else { showLegacyFullSync = true }
    }
    func reviewLegacyFullSync() { reviewLibrarySync() }
    func requestOriginalGamesReview() {
        guard deviceManager.consoleType == .snesUsa, canReviewLibrarySync else { return }
        returnOriginalsAfterClosing = true
    }
    func openRequestedOriginalGamesReview() {
        guard returnOriginalsAfterClosing else { return }
        returnOriginalsAfterClosing = false
        guard deviceManager.consoleType == .snesUsa, canReviewLibrarySync else { return }
        isPreparingSync = true; snesLibraryOriginalsOnly = true; showSNESLibrarySync = true
    }

    func reviewLegacyArchiveReclaim() {
        guard deviceManager.consoleType == .nes, deviceManager.legacyReport != nil, deviceManager.legacyClient != nil, !taskRunner.isRunning,
              !isPreparingSync, !gameManager.isLoading else { return }
        isPreparingSync = true
        showLegacyArchiveReclaim = true
    }

    func reviewLegacyChange(game: Game? = nil) {
        guard deviceManager.consoleType == .nes, deviceManager.legacyReport != nil, deviceManager.legacyClient != nil, !taskRunner.isRunning, !isPreparingSync, !gameManager.isLoading else { return }
        legacyChangeGame = game
        legacyChangeWorkspace = AppConfig.shared.workspace
        legacyChangeSession = deviceManager.sessionID
        isPreparingSync = true; showLegacyChange = true
    }
    func refreshLegacyLibraryAfterChange() async {
        do { try await deviceManager.refreshLegacyReport(); await onConsoleConnected() }
        catch { reportOperationError("Change recorded, but the library could not refresh: " + error.localizedDescription) }
    }
    @Published var isPreparingSync = false
    private var snesTrialInProgress = false
    @Published var showCodeCatalog = false
    @Published var showFolders = false
    @Published var operationError: String?
    @Published var showOperationError = false
    @Published var preparedPlan: SyncPlan?
    private var preparedInventory: DeviceInventory?


    // MARK: - UI State
    @Published var selectedGame: Game?
    @Published var searchText = ""
    @Published var showScraper = false
    @Published var showModuleManager = false
    @Published var showHelp = false
    var recoveryContext: ConsoleRecoveryContext {
        ConsoleRecoveryContext(connected: deviceManager.consoleType, selected: connectionConfig.lastConsoleType)
    }
    @Published var showRecoveryReadiness = false
    @Published var showSNESBackup = false
    @Published var showTaskProgress = false
    @Published var showWaitingForDevice = false
    @Published var showInstallConfig = false
    @Published var statusMessage: String?
    @Published var legacyCapacityPreview: LegacySyncCapacityEstimate.Projection?
    @Published var showSyncConfirmation = false
    @Published var showDeleteConfirmation = false
    @Published var showRemoveLocalLibrary = false
    var syncRemovedCount = 0

    // MARK: - Flash state
    @Published var pendingFlashOperation: FlashOperation?
    var pendingBackupSettings: BackupSettings?
    var pendingKernelImage: Data?

    private var cancellables = Set<AnyCancellable>()

    init(startDeviceMonitoring: Bool = true, deviceManager: DeviceManager? = nil,
         gameManager: GameManagerService? = nil, config: AppConfig = .shared,
         saveConfiguration: (() -> Void)? = nil,
         checkRecoveryHost: @escaping @Sendable () async throws -> Void = { try await RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
         firmwareJournalRoot: @escaping @Sendable () throws -> URL = { try SNESFirmwareJournalPolicy.ensureRoot() },
         makeSNESFirmwareIO: @escaping @Sendable (SNESFirmwareMaterial, SNESFirmwareGuard) throws -> any SNESFirmwareIO = { try NativeSNESFirmwareIO(material: $0, guard: $1) },
         makeSNESInstalledStartupIO: @escaping @Sendable (PreparedSNESStartupTrial) throws -> any SNESInstalledStartupIO = { NativeSNESInstalledStartupIO(trial: $0) },
         makeSNESMenuStartupPreflightIO: @escaping @Sendable (SNESStartupAdapterCandidate, SNESMenuStartupParent) throws -> any SNESStartupPreflightIO = { try NativeSNESStartupPreflightIO(candidate: $0, parent: $1) },
         makeSNESPreparationIO: @escaping @Sendable (SNESPreparationSource) -> any SNESPreparationIO = { NativeSNESPreparationIO(source: $0) },
         makeSNESMenuSupportIO: @escaping @Sendable (SNESMenuSupportSource) -> any SNESMenuSupportIO = { NativeSNESMenuSupportIO(source: $0) },
         makeSNESOriginalComponentIO: @escaping @Sendable (SNESOriginalComponentSource) -> any SNESOriginalComponentIO = { NativeSNESOriginalComponentIO(source: $0) },
         makeSNESDataSnapshotIO: @escaping @Sendable (SNESPreparationSource) -> any SNESDataSnapshotIO = { NativeSNESDataSnapshotIO(source: $0) },
         makeSNESRuntimeIO: @escaping @Sendable () -> any RecoveryProbeIO = { NativeRecoveryProbeIO(observationCommand: SNESBackupPolicy.command) },
         makeSNESStartupPreflightIO: @escaping @Sendable (SNESStartupAdapterCandidate) throws -> any SNESStartupPreflightIO = { try NativeSNESStartupPreflightIO(candidate: $0) },
         makeSNESStartupTrialIO: @escaping @Sendable (PreparedSNESStartupTrial) throws -> any SNESStartupTrialIO = { NativeSNESStartupTrialIO(trial: $0) },
         makeSNESActiveBoot2IO: @escaping @Sendable (SNESPreparationSource, SNESBoundedReadHelper) -> any SNESActiveBoot2IO = { NativeSNESActiveBoot2IO(source: $0, helper: $1) }) {
        self.deviceManager = deviceManager ?? DeviceManager()
        self.gameManager = gameManager ?? GameManagerService(config: config)
        self.connectionConfig = config
        self.saveConnectionConfiguration = saveConfiguration ?? { config.save() }
        self.checkRecoveryHost = checkRecoveryHost
        self.firmwareJournalRoot = firmwareJournalRoot
        self.makeSNESFirmwareIO = makeSNESFirmwareIO
        self.makeSNESInstalledStartupIO = makeSNESInstalledStartupIO
        self.makeSNESMenuStartupPreflightIO = makeSNESMenuStartupPreflightIO
        self.makeSNESPreparationIO = makeSNESPreparationIO
        self.makeSNESMenuSupportIO = makeSNESMenuSupportIO
        self.makeSNESOriginalComponentIO = makeSNESOriginalComponentIO
        self.makeSNESDataSnapshotIO = makeSNESDataSnapshotIO
        self.makeSNESRuntimeIO = makeSNESRuntimeIO
        self.makeSNESStartupPreflightIO = makeSNESStartupPreflightIO
        self.makeSNESStartupTrialIO = makeSNESStartupTrialIO
        self.makeSNESActiveBoot2IO = makeSNESActiveBoot2IO

        // Forward objectWillChange from nested ObservableObjects
        self.deviceManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        self.gameManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        taskRunner.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // When device connects/disconnects, pull or clear console games
        self.deviceManager.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    Task { await self.onConsoleConnected() }
                } else {
                    self.gameManager.clearConsoleGames()
                    self.gameManager.isLoading = false
                    self.selectedGame = nil
                    self.statusMessage = nil
                }
            }
            .store(in: &cancellables)

        // When FEL device appears and we have a pending operation, start it
        self.deviceManager.$felDevicePresent
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] present in
                guard let self, present, let operation = self.pendingFlashOperation else { return }
                guard self.showWaitingForDevice else { return }
                logger.info("FEL device detected, starting pending operation")
                self.showWaitingForDevice = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    self.startFlashOperation(operation)
                }
            }
            .store(in: &cancellables)

        if startDeviceMonitoring { self.deviceManager.start() }
    }

    // MARK: - Library Enrichment

    func fillMissingCoverArt() {
        guard !gameManager.isInspectingLegacy, !taskRunner.isRunning, !isPreparingSync else { return }
        showTaskProgress = true
        taskRunner.run(name: "Finding missing box art") { [weak self] runner in
            guard let self else { return }
            let report = try await self.gameManager.fillMissingCoverArt { status, fraction in
                runner.updateProgress(status: status, fraction: fraction)
            }
            runner.updateProgress(status: report.summary, fraction: 1)
            await MainActor.run { self.statusMessage = report.summary }
        }
    }

    // MARK: - Console connection

    /// Adopt only the current verified session, before remote library reads can fail.
    @discardableResult func adoptConnectedLibrary(session: UUID) -> Bool {
        guard deviceManager.isConnected, deviceManager.sessionID == session,
              deviceManager.consoleType != .unknown else { return false }
        let type = deviceManager.consoleType
        let changed = connectionConfig.lastConsoleType != type
        gameManager.clearConsoleGames()
        selectedGame = nil; searchText = ""
        preparedPlan = nil; preparedInventory = nil; legacyCapacityPreview = nil
        if changed || (!deviceManager.uniqueId.isEmpty && connectionConfig.lastDeviceId != deviceManager.uniqueId) {
            connectionConfig.lastDeviceId = deviceManager.uniqueId
            connectionConfig.installedGameCodes = []
        }
        connectionConfig.lastConsoleType = type
        saveConnectionConfiguration()
        gameManager.loadGames()
        return true
    }

    func onConsoleConnected() async {
        let token = deviceManager.sessionID
        guard adoptConnectedLibrary(session: token) else { return }
        if let client = deviceManager.legacyClient, let report = deviceManager.legacyReport,
           deviceManager.consoleType == .nes {
            gameManager.mergeInspectionGames([])
            gameManager.isLoading = true
            statusMessage = "Reading console games…"
            defer { if deviceManager.sessionID == token { gameManager.isLoading = false } }
            do {
                let remote = try await LegacyConsoleService.games(client: client, report: report)
                guard deviceManager.sessionID == token, deviceManager.isConnected else { return }
                gameManager.mergeInspectionGames(remote)
                statusMessage = "NES connected. Choose Sync Library to review your game updates."
            } catch {
                let active = await client.isConnected
                guard deviceManager.sessionID == token else { return }
                if !active { deviceManager.manualDisconnect() }
                statusMessage = "Console games could not be read. Your local library is ready."
                reportOperationError(error.localizedDescription)
            }
            return
        }
        if deviceManager.consoleType == .snesUsa, let context = deviceManager.nativeSNESContext {
            do { try gameManager.rememberSNESOriginalGames(context.installation.originals.frame) }
            catch { reportOperationError("The built-in game names could not be read for duplicate hints.") }
            statusMessage = context.supportsLibrarySync
                ? "SNES connected. Choose Sync Library to review your games."
                : "SNES connected. Complete Console Setup before syncing games."
            return
        }
        guard deviceManager.consoleType == .nes, let shell = deviceManager.sshService else {
            deviceManager.canSync = false
            statusMessage = deviceManager.consoleType.displayName + " library ready. Console game transfer is not available for this model yet."
            return
        }
        let consoleType = deviceManager.consoleType
        statusMessage = "Reading console inventory…"
        do {
            let inventory = try await DeviceInventoryService.inspect(shell: shell)
            guard inventory.consoleType == consoleType else { throw SyncPlanError.unsupportedConsole }
            let remote = try await ConsoleLibraryService.read(inventory: inventory, shell: shell)
            guard applyConnectedInventory(inventory, remote: remote, session: token) else { return }
            statusMessage = deviceManager.canSync ? nil : "Inspection only: game transfer is not available for this console yet."
        } catch {
            guard deviceManager.sessionID == token, deviceManager.isConnected else { return }
            deviceManager.canSync = false
            statusMessage = "Console inventory could not be read. Your local library is ready."
            reportOperationError(error.localizedDescription)
        }
    }

    @discardableResult func applyConnectedInventory(_ inventory: DeviceInventory, remote: [Game], session: UUID) -> Bool {
        let deviceID = inventory.profile.deviceID
        guard deviceManager.sessionID == session, deviceManager.isConnected,
              inventory.consoleType == .nes, deviceManager.consoleType == inventory.consoleType,
              deviceID.range(of: #"^[A-Za-z0-9:_-]+$"#, options: .regularExpression) != nil,
              deviceManager.uniqueId.isEmpty || deviceManager.uniqueId == deviceID else { return false }
        deviceManager.uniqueId = deviceID
        connectionConfig.lastDeviceId = deviceID
        connectionConfig.installedGameCodes = Array(inventory.installedCodes)
        saveConnectionConfiguration()
        gameManager.mergeConsoleGames(remote, installedCodes: inventory.installedCodes, deviceID: deviceID,
            consoleType: inventory.consoleType, visibleCodes: inventory.visibleCodes)
        deviceManager.canSync = inventory.canSync
        return true
    }

    func changeLibraryConsole(to console: ConsoleType) {
        guard console != .unknown, !taskRunner.isRunning, !isPreparingSync, !gameManager.isLoading else { return }
        deviceManager.manualDisconnect()
        gameManager.clearConsoleGames()
        if connectionConfig.lastConsoleType != console {
            connectionConfig.lastDeviceId = ""
            connectionConfig.installedGameCodes = []
        }
        connectionConfig.lastConsoleType = console
        saveConnectionConfiguration()
        selectedGame = nil; searchText = ""
        gameManager.loadGames()
        statusMessage = console.displayName + " library selected. Choose Connect when its console is attached."
    }

    func removeLocalLibrary() {
        guard !taskRunner.isRunning, !isPreparingSync, !gameManager.isLoading else { return }
        deviceManager.manualDisconnect()
        gameManager.clearConsoleGames()
        do {
            let directory = try gameManager.archiveLocalLibrary()
            selectedGame = nil; searchText = ""
            statusMessage = "Imported library removed. The recoverable copy is in Removed Libraries on this Mac."
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch { reportOperationError(error.localizedDescription) }
    }

    func reviewSNESBackup() {
        guard connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning,
              !isPreparingSync, !gameManager.isLoading else { return }
        isPreparingSync = true
        showSNESBackup = true
    }

    private enum SNESSavedCapture { case kernel(URL), setup(SNESSetupRecordReceipt) }
    func captureSNESKernel(progress: @escaping RecoveryProgressSink) async throws -> URL {
        guard case .kernel(let directory) = try await captureSNES(progress: progress, includeSetupEvidence: false) else { throw SNESRuntimeBinding.failure() }
        return directory
    }

    func captureSNESSetup(progress: @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt {
        guard case .setup(let receipt) = try await captureSNES(progress: progress, includeSetupEvidence: true) else { throw SNESRuntimeBinding.failure() }
        return receipt
    }

    nonisolated static func loadSelectedSNESBackup(_ receipt: SNESSetupRecordReceipt) throws -> SNESOfflineSource {
        guard receipt.kind == .backup else { throw SNESRuntimeBinding.failure() }
        let source = try SNESOfflineSource.load(snapshot: receipt.directory)
        guard source.manifestSHA256 == receipt.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        return source
    }

    /// Build and re-open a portable recovery package from this console's saved
    /// setup backup. This is Mac-only preparation, not restore authorization.
    func prepareSNESRecoveryPackage(from backup: SNESSetupRecordReceipt) async throws -> URL {
        let root = connectionConfig.workspace.backups
        return try await Self.runSNESRecoveryWorker {
            let source = try Self.loadSelectedSNESBackup(backup)
            let material = try SNESRecoveryMaterial.load(setup: backup.directory)
            try source.revalidate()
            let store = try RecoveryBootSnapshotStore(root: root)
            return try await store.saveSNESRecoveryMaterial(material)
        }
    }

    /// Save the exact checked helper bytes alongside this Mac's recovery files.
    /// This does not contact the console or authorize a firmware operation.
    func prepareSNESSetupHelpers() async throws -> URL {
        let root = connectionConfig.workspace.backups
        return try await Self.runSNESRecoveryWorker {
            let store = try RecoveryBootSnapshotStore(root: root)
            return try await store.saveSNESPortableHelpers()
        }
    }

    /// Check the same console in temporary memory. No firmware is installed.
    func checkSNESStartup(backup: SNESSetupRecordReceipt, recovery: URL, helpers: URL,
                          progress: @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa,
              !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before starting this check.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES setup operation is already running.") }
        snesTrialInProgress = true
        defer { snesTrialInProgress = false }
        await progress(.checkingMaterial)
        let selectedEvidence = SNESSetupSelectedBinding.current
        let (source, savedRecovery, savedHelpers) = try await Self.runSNESRecoveryWorker {
            let source = try SNESPreparationSource.load(Self.loadSelectedSNESBackup(backup))
            let savedRecovery = try SNESRecoveryMaterial.loadPackage(directory: recovery)
            try selectedEvidence?.requireSources(backup: source.source)
            try savedRecovery.requireExactSource(SNESRecoveryMaterial.load(setup: backup.directory))
            let savedHelpers = try SNESPortableHelperPackage.load(directory: helpers)
            try savedRecovery.requireHardwareID(source.source.expectedHWID)
            guard savedRecovery.stock == source.stock, savedRecovery.partitions == source.partitions else {
                throw SNESOfflineSource.failure()
            }
            return (source, savedRecovery, savedHelpers)
        }
        let inputs = try await payloads.pinnedRecoveryInputs()
        _ = try inputs.prepare()
        try await checkRecoveryHost()
        try source.revalidate(); try savedRecovery.revalidate(); try savedHelpers.revalidate()
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let store = try RecoveryBootSnapshotStore(root: connectionConfig.workspace.backups)
        do {
            let result = try await SNESRecoveryPreparationService().capture(
                source: source, inputs: inputs, io: makeSNESPreparationIO(source), progress: progress)
            return try await store.saveSNESPreparationWithReceipt(result)
        } catch let failure as SNESPreparationFailure {
            let directory = try await store.saveSNESPreparationFailure(failure)
            throw SNESPreparationDiagnosticSavedError(directory: directory)
        }
    }

    /// Capture the verified original menu support files in temporary recovery.
    func captureSNESMenuSupport(backup: SNESSetupRecordReceipt, recovery: URL, helpers: URL, startup: SNESSetupRecordReceipt,
                                progress: @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa,
              !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before starting this check.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES setup operation is already running.") }
        snesTrialInProgress = true
        defer { snesTrialInProgress = false }
        await progress(.checkingMaterial)
        let selectedEvidence = SNESSetupSelectedBinding.current
        let (source, savedRecovery, savedHelpers) = try await Self.runSNESRecoveryWorker {
            let setup = try Self.loadSelectedSNESBackup(backup)
            let source = try SNESMenuSupportSource.load(setup: setup, preparation: startup.directory)
            guard startup.kind == .startup, source.manifestSHA256 == startup.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
            let savedRecovery = try SNESRecoveryMaterial.loadPackage(directory: recovery)
            try selectedEvidence?.requireSources(backup: setup, startup: source)
            try savedRecovery.requireExactSource(SNESRecoveryMaterial.load(setup: backup.directory))
            let savedHelpers = try SNESPortableHelperPackage.load(directory: helpers)
            try savedRecovery.requireHardwareID(setup.expectedHWID)
            guard savedRecovery.stock == setup.stock,
                  savedRecovery.partitions == source.preparation.source.partitions else {
                throw SNESOfflineSource.failure()
            }
            return (source, savedRecovery, savedHelpers)
        }
        let inputs = try await payloads.pinnedRecoveryInputs()
        _ = try inputs.prepare()
        try await checkRecoveryHost()
        try source.revalidate(); try savedRecovery.revalidate(); try savedHelpers.revalidate()
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let store = try RecoveryBootSnapshotStore(root: connectionConfig.workspace.backups)
        do {
            let result = try await SNESMenuSupportService().capture(
                source: source, inputs: inputs, io: makeSNESMenuSupportIO(source), progress: progress)
            return try await store.saveSNESMenuSupportWithReceipt(result)
        } catch let failure as SNESMenuSupportFailure {
            let directory = try await store.saveSNESMenuSupportFailure(failure)
            throw SNESPreparationDiagnosticSavedError(directory: directory)
        }
    }

    /// Capture original components without changing console storage.
    func captureSNESOriginalComponents(backup: SNESSetupRecordReceipt, recovery: URL, helpers: URL, startup: SNESSetupRecordReceipt, support: SNESSetupRecordReceipt,
                                       progress: @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa,
              !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before starting this check.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES setup operation is already running.") }
        snesTrialInProgress = true
        defer { snesTrialInProgress = false }
        await progress(.checkingMaterial)
        let selectedEvidence = SNESSetupSelectedBinding.current
        let (source, savedRecovery, savedHelpers) = try await Self.runSNESRecoveryWorker {
            let setup = try Self.loadSelectedSNESBackup(backup)
            let preparation = try SNESMenuSupportSource.load(setup: setup, preparation: startup.directory)
            guard startup.kind == .startup, preparation.manifestSHA256 == startup.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
            let material = try SNESMenuSupportMaterial.load(source: preparation, directory: support.directory)
            guard support.kind == .menuSupport, material.manifestSHA256 == support.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
            let source = try SNESOriginalComponentSource(material: material)
            let savedRecovery = try SNESRecoveryMaterial.loadPackage(directory: recovery)
            try selectedEvidence?.requireSources(backup: setup, startup: preparation, support: material)
            try savedRecovery.requireExactSource(SNESRecoveryMaterial.load(setup: backup.directory))
            let savedHelpers = try SNESPortableHelperPackage.load(directory: helpers)
            try savedRecovery.requireHardwareID(setup.expectedHWID)
            guard savedRecovery.stock == setup.stock,
                  savedRecovery.partitions == preparation.preparation.source.partitions else {
                throw SNESOfflineSource.failure()
            }
            return (source, savedRecovery, savedHelpers)
        }
        let inputs = try await payloads.pinnedRecoveryInputs()
        _ = try inputs.prepare()
        try await checkRecoveryHost()
        try source.revalidate(); try savedRecovery.revalidate(); try savedHelpers.revalidate()
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let store = try RecoveryBootSnapshotStore(root: connectionConfig.workspace.backups)
        var captured: SNESOriginalComponentResult?
        do {
            let result = try await SNESOriginalComponentService().capture(
                source: source, inputs: inputs, io: makeSNESOriginalComponentIO(source), progress: progress)
            captured = result
            return try await store.saveSNESOriginalComponentsWithReceipt(result)
        } catch {
            if error is RecoverySnapshotCleanupError { throw error }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure: SNESOriginalComponentFailure
            if let existing = error as? SNESOriginalComponentFailure { failure = existing }
            else if let captured { failure = .init(source: source, stage: "saving-result", frame: captured.frame.raw) }
            else { throw error }
            let directory = try await store.saveSNESOriginalComponentFailure(failure)
            throw SNESPreparationDiagnosticSavedError(directory: directory)
        }
    }

    /// Copy the console data read-only, and verify it before reporting success.
    func backupSNESData(backup: SNESSetupRecordReceipt, recovery: URL, helpers: URL, chain: SNESSetupRecordChain, progress: @escaping RecoveryProgressSink,
                        detail: @escaping @Sendable (String) async -> Void) async throws -> SNESDataSnapshotReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before starting this backup.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES setup operation is already running.") }
        snesTrialInProgress = true
        defer { snesTrialInProgress = false }
        await progress(.checkingMaterial)
        let root = connectionConfig.workspace.backups
        let selectedEvidence = SNESSetupSelectedBinding.current
        let (source, savedRecovery, savedHelpers, components, store) = try await Self.runSNESRecoveryWorker {
            let setup = try Self.loadSelectedSNESBackup(backup)
            try selectedEvidence?.requireSources(backup: setup)
            let components = try chain.load(setup: setup)
            let source = try SNESPreparationSource.load(setup)
            let savedRecovery = try SNESRecoveryMaterial.loadPackage(directory: recovery)
            try savedRecovery.requireExactSource(SNESRecoveryMaterial.load(setup: backup.directory))
            let savedHelpers = try SNESPortableHelperPackage.load(directory: helpers)
            let store = try RecoveryBootSnapshotStore(root: root)
            try await store.checkWritableDestination()
            let plan = try source.dataSnapshotPlan()
            guard let available = try SNESBackupCapacity.available(at: root),
                  available >= Int64(plan.byteCount) + 32 * 1024 * 1024 else {
                throw RecoveryProbeError.refused("This Mac needs more free space for the console data backup. Nothing was sent to the console.")
            }
            return (source, savedRecovery, savedHelpers, components, store)
        }
        let inputs = try await payloads.pinnedRecoveryInputs(); _ = try inputs.prepare()
        try await checkRecoveryHost()
        try await Self.runSNESRecoveryWorker {
            try source.revalidate(); try savedRecovery.revalidate(); try savedHelpers.revalidate(); try components.revalidate()
        }
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let checked = try await SNESDataSnapshotService().captureAndSave(source: source, inputs: inputs,
            io: makeSNESDataSnapshotIO(source), progress: progress, detail: detail, save: { result in
                try await Self.runSNESRecoveryWorker { try components.revalidate() }
                return try await store.saveSNESDataSnapshotWithReceipt(result, verify: { _ in try components.revalidate() })
            })
        return checked.backup
    }

    /// Capture the original runtime libraries read-only for this setup.
    func captureSNESRuntime(backup: SNESSetupRecordReceipt, recovery: URL, helpers: URL, chain: SNESSetupRecordChain, data: SNESDataSnapshotReceipt,
                            progress: @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before starting this check.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES setup operation is already running.") }
        snesTrialInProgress = true
        defer { snesTrialInProgress = false }
        await progress(.checkingMaterial)
        let root = connectionConfig.workspace.backups
        let selectedEvidence = SNESSetupSelectedBinding.current
        let (source, savedRecovery, savedHelpers, components, dataBackup, store) = try await Self.runSNESRecoveryWorker {
            let source = try Self.loadSelectedSNESBackup(backup)
            try selectedEvidence?.requireSources(backup: source)
            let components = try chain.load(setup: source)
            let savedRecovery = try SNESRecoveryMaterial.loadPackage(directory: recovery)
            try savedRecovery.requireExactSource(SNESRecoveryMaterial.load(setup: backup.directory))
            let savedHelpers = try SNESPortableHelperPackage.load(directory: helpers)
            let dataBackup = try SNESDataSnapshotPackage.load(receipt: data, source: SNESPreparationSource.load(source))
            let store = try RecoveryBootSnapshotStore(root: root)
            try await store.checkWritableDestination()
            return (source, savedRecovery, savedHelpers, components, dataBackup, store)
        }
        let inputs = try await payloads.pinnedRecoveryInputs(); _ = try inputs.prepare()
        try await checkRecoveryHost()
        try await Self.runSNESRecoveryWorker {
            try source.revalidate(); try savedRecovery.revalidate(); try savedHelpers.revalidate(); try components.revalidate()
        }
        try await Self.runSNESRecoveryWorker { try dataBackup.revalidate() }
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let runtime = try await SNESRuntimeCaptureService().capture(binding: source.runtimeBinding,
            inputs: inputs, io: makeSNESRuntimeIO(), progress: progress)
        try await Self.runSNESRecoveryWorker { try components.revalidate(); try dataBackup.revalidate() }
        return try await store.saveSNESRuntimeWithReceipt(runtime, source: source, verify: { _ in
            try components.revalidate(); try dataBackup.revalidate()
        })
    }

    /// Prepare a startup image on this Mac. This does not access the console.
    func prepareSNESStartupCandidate(backup: SNESSetupRecordReceipt, recovery: URL, helpers: URL,
                                     chain: SNESSetupRecordChain, data: SNESDataSnapshotReceipt,
                                     runtime: SNESSetupRecordReceipt, progress: @escaping RecoveryProgressSink,
                                     loadTools: @escaping @Sendable () async throws -> SNESStartupToolInputs = { try await SNESStartupToolInputs.acquire() }) async throws -> SNESSetupRecordReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before preparing startup files.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES setup operation is already running.") }
        snesTrialInProgress = true
        defer { snesTrialInProgress = false }
        await progress(.checkingMaterial)
        let root = connectionConfig.workspace.backups
        let selectedEvidence = SNESSetupSelectedBinding.current
        let (material, savedRecovery, savedHelpers, dataBackup, store) = try await Self.runSNESRecoveryWorker {
            let source = try Self.loadSelectedSNESBackup(backup)
            try selectedEvidence?.requireSources(backup: source)
            let components = try chain.load(setup: source)
            let savedRecovery = try SNESRecoveryMaterial.loadPackage(directory: recovery)
            try savedRecovery.requireExactSource(SNESRecoveryMaterial.load(setup: backup.directory))
            let savedHelpers = try SNESPortableHelperPackage.load(directory: helpers)
            let dataBackup = try SNESDataSnapshotPackage.load(receipt: data, source: SNESPreparationSource.load(source))
            let savedRuntime = try SNESRuntimeMaterial.load(directory: runtime.directory, source: source)
            try savedRuntime.requireReceipt(runtime)
            let material = try SNESOriginalMenuMaterial(components: components, runtime: savedRuntime)
            let store = try RecoveryBootSnapshotStore(root: root)
            try await store.checkWritableDestination()
            return (material, savedRecovery, savedHelpers, dataBackup, store)
        }
        let tools = try await loadTools()
        return try await Self.runSNESRecoveryWorker {
            try selectedEvidence?.revalidate()
            try material.revalidate(); try savedRecovery.revalidate(); try savedHelpers.revalidate(); try dataBackup.revalidate()
            // The first-install preflight accepts the base recipe only. Menu
            // and library support are separately verified upgrades of an
            // accepted installation, not evidence for a stock console.
            let candidate = try SNESStartupAdapterCandidate.prepare(material: material, daemonHmod: tools.daemonHmod, busybox: tools.busybox, backup: dataBackup)
            guard !candidate.hasMenuSupport else { throw SNESRuntimeBinding.failure() }
            return try await store.saveSNESStartupCandidateWithReceipt(candidate, verify: { _ in
                try selectedEvidence?.revalidate(); try savedRecovery.revalidate(); try savedHelpers.revalidate()
                try material.revalidate(); try dataBackup.revalidate()
            })
        }
    }

    nonisolated private static func loadSelectedSNESCandidate(_ receipt: SNESSetupRecordReceipt) throws -> SNESStartupAdapterCandidate {
        guard receipt.kind == .candidate, receipt.manifestSHA256.count == 64, SNESRuntimeBinding.hex(receipt.manifestSHA256) else { throw SNESRuntimeBinding.failure() }
        let directory = try RestoreDirectory(receipt.directory)
        guard BackupManifest.digest(try directory.read("manifest.json", maximum: 65536)) == receipt.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        let candidate = try SNESStartupAdapterCandidate.load(directory: receipt.directory, expectedManifestSHA256: receipt.manifestSHA256)
        guard !candidate.hasMenuSupport,
              BackupManifest.digest(try directory.read("manifest.json", maximum: 65536)) == receipt.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        try directory.check()
        return candidate
    }
    /// The candidate was already reconstructed against this exact receipt.
    /// Check its saved bytes without rebuilding the image at every USB step.
    nonisolated static func requireSavedSNESCandidate(_ receipt: SNESSetupRecordReceipt, image: Data) throws {
        guard receipt.kind == .candidate, receipt.manifestSHA256.count == 64, SNESRuntimeBinding.hex(receipt.manifestSHA256) else { throw SNESRuntimeBinding.failure() }
        let directory = try RestoreDirectory(receipt.directory)
        guard Set(try directory.names()) == Set(["manifest.json", "startup.img"]),
              BackupManifest.digest(try directory.read("manifest.json", maximum: 65536)) == receipt.manifestSHA256,
              try directory.read("startup.img") == image else { throw SNESRuntimeBinding.failure() }
        try directory.check()
    }

    /// Read-only console checks and RAM staging; no firmware or games are written.
    func checkSNESStartupCandidate(_ receipt: SNESSetupRecordReceipt, progress: @escaping RecoveryProgressSink) async throws -> SNESStartupPreflightReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before starting this check.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES setup operation is already running.") }
        snesTrialInProgress = true
        defer { snesTrialInProgress = false }
        await progress(.checkingMaterial)
        let selectedEvidence = SNESSetupSelectedBinding.current, root = connectionConfig.workspace.backups
        let (candidate, store) = try await Self.runSNESRecoveryWorker {
            let candidate = try Self.loadSelectedSNESCandidate(receipt)
            try selectedEvidence?.requireSources(backup: candidate.material.support.setup)
            try selectedEvidence?.revalidate()
            let store = try RecoveryBootSnapshotStore(root: root)
            try await store.checkWritableDestination()
            return (candidate, store)
        }
        let inputs = try await payloads.pinnedRecoveryInputs(); _ = try inputs.prepare()
        try await checkRecoveryHost()
        try await Self.runSNESRecoveryWorker {
            _ = try Self.loadSelectedSNESCandidate(receipt); try selectedEvidence?.revalidate()
        }
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let io = try makeSNESStartupPreflightIO(candidate)
        let result = try await SNESStartupPreflightService().capture(candidate: candidate, inputs: inputs, io: io, progress: progress)
        return try await store.saveSNESStartupPreflightWithReceipt(result, verify: { _ in
            _ = try Self.loadSelectedSNESCandidate(receipt); try selectedEvidence?.revalidate()
        })
    }

    /// Start or recheck a temporary startup; this never writes firmware.
    func runSNESStartupTrial(candidate candidateReceipt: SNESSetupRecordReceipt, preflight: SNESStartupPreflightReceipt,
                             started startedReceipt: SNESSetupRecordReceipt? = nil,
                             progress: @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before starting this test.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("The temporary startup check is already running.") }
        snesTrialInProgress = true
        defer { snesTrialInProgress = false }
        await progress(.checkingMaterial)
        let root = connectionConfig.workspace.backups, selectedEvidence = SNESSetupSelectedBinding.current
        let inputs = try await payloads.pinnedRecoveryInputs()
        let (trial, started, store) = try await Self.runSNESRecoveryWorker {
            let candidate = try Self.loadSelectedSNESCandidate(candidateReceipt)
            try selectedEvidence?.requireSources(backup: candidate.material.support.setup); try selectedEvidence?.revalidate()
            let trial = try PreparedSNESStartupTrial.prepare(candidate: candidate, receipt: preflight, recovery: inputs)
            let started = try startedReceipt.map { try SNESStartupTrialResult.loadStarted(receipt: $0, trial: trial) }
            let store = try RecoveryBootSnapshotStore(root: root)
            try await store.checkWritableDestination()
            return (trial, started, store)
        }
        let validate: @Sendable () throws -> Void = {
            try Self.requireSavedSNESCandidate(candidateReceipt, image: trial.image)
            try selectedEvidence?.revalidate()
            guard preflight.backupMatches, preflight.record.kind == .preflight,
                  preflight.record.directory == trial.evidence.directory,
                  preflight.record.manifestSHA256 == trial.evidence.manifestSHA256,
                  preflight.backupMatches == trial.evidence.backupMatches else { throw SNESRuntimeBinding.failure() }
            if let startedReceipt {
                guard let started else { throw SNESRuntimeBinding.failure() }
                try started.requireSavedReceipt(startedReceipt)
            }
        }
        try await checkRecoveryHost()
        try await Self.runSNESRecoveryWorker { try trial.validateCurrent(); try validate() }
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let io = try makeSNESStartupTrialIO(trial)
        do {
            let result = try await SNESStartupTrialService().capture(trial: trial, started: started, io: io,
                progress: progress, validateInputs: validate)
            if let startedReceipt {
                return try await store.saveSNESStartupTrialPlayedWithReceipt(result, trial: trial, started: startedReceipt, verify: { _ in try validate() })
            }
            return try await store.saveSNESStartupTrialStartedWithReceipt(result, trial: trial, verify: { _ in try validate() })
        } catch let failure as SNESStartupTrialFailure {
            let directory = try await store.saveSNESStartupTrialFailure(failure, trial: trial)
            throw SNESPreparationDiagnosticSavedError(directory: directory)
        }
    }

    /// Save the active startup area without granting firmware-write authority.
    func captureSNESActiveStartup(backup: SNESSetupRecordReceipt, helpers: URL, candidate candidateReceipt: SNESSetupRecordReceipt,
                                  preflight: SNESStartupPreflightReceipt, started: SNESSetupRecordReceipt, played: SNESSetupRecordReceipt,
                                  progress: @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before saving the startup area.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES startup check is already running.") }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        await progress(.checkingMaterial)
        let root = connectionConfig.workspace.backups, selectedEvidence = SNESSetupSelectedBinding.current
        let inputs = try await payloads.pinnedRecoveryInputs()
        let (source, helperPackage, trial, proof, store) = try await Self.runSNESRecoveryWorker {
            let setup = try Self.loadSelectedSNESBackup(backup)
            try selectedEvidence?.requireSources(backup: setup); try selectedEvidence?.revalidate()
            let candidate = try Self.loadSelectedSNESCandidate(candidateReceipt)
            guard candidate.material.support.setup.directoryURL == setup.directoryURL,
                  candidate.material.support.setup.manifestSHA256 == setup.manifestSHA256,
                  started.kind == .trialStarted, played.kind == .trialPlayed else { throw SNESRuntimeBinding.failure() }
            let trial = try PreparedSNESStartupTrial.prepare(candidate: candidate, receipt: preflight, recovery: inputs)
            let proof = try SNESFirmwareTrialProof.load(started: started.directory, played: played.directory, trial: trial,
                expectedStartedSHA256: started.manifestSHA256, expectedPlayedSHA256: played.manifestSHA256)
            let source = try SNESPreparationSource.load(setup), helperPackage = try SNESPortableHelperPackage.load(directory: helpers)
            let store = try RecoveryBootSnapshotStore(root: root); try await store.checkWritableDestination()
            guard let available = try SNESBackupCapacity.available(at: root),
                  available >= 7340032 + 16 * 1024 * 1024 else { throw RecoveryProbeError.refused("This Mac needs about 24 MB free for the startup backup. Nothing was sent to the console.") }
            return (source, helperPackage, trial, proof, store)
        }
        let validate: @Sendable () throws -> Void = {
            try selectedEvidence?.revalidate(); try helperPackage.revalidate()
            try Self.requireSavedSNESCandidate(candidateReceipt, image: trial.image)
            try trial.evidence.requireReceipt(preflight, candidate: trial.candidate); try proof.revalidate(trial: trial)
        }
        try await checkRecoveryHost(); try await Self.runSNESRecoveryWorker { try validate() }
        await deviceManager.pauseForRecovery(); defer { deviceManager.waitForNormalBootAfterRecovery() }
        do {
            let result = try await SNESActiveBoot2SnapshotService().capture(source: source, inputs: inputs,
                helper: helperPackage.reader, io: makeSNESActiveBoot2IO(source, helperPackage.reader), progress: progress)
            try await Self.runSNESRecoveryWorker { try validate() }
            return try await store.saveSNESActiveBoot2WithReceipt(result, verify: { _ in try validate() })
        } catch let failure as SNESActiveBoot2Failure {
            let directory = try await store.saveSNESActiveBoot2Failure(failure)
            throw SNESPreparationDiagnosticSavedError(directory: directory)
        }
    }

    /// Save an inert Mac-only review; no journal or console connection is opened.
    func prepareSNESFirmwarePlan(backup: SNESSetupRecordReceipt, helpers: URL, candidate: SNESSetupRecordReceipt,
                                 preflight: SNESStartupPreflightReceipt, started: SNESSetupRecordReceipt,
                                 played: SNESSetupRecordReceipt, active: SNESSetupRecordReceipt,
                                 currentData: SNESDataSnapshotReceipt) async throws -> SNESFirmwarePreparationReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before preparing an installation review.")
        }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES startup check is already running.") }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let selectedEvidence = SNESSetupSelectedBinding.current
        let backupRoot = snesBackupsDirectory
        let inputs = try await payloads.pinnedRecoveryInputs()
        return try await Self.runSNESRecoveryWorker {
            try selectedEvidence?.revalidate()
            let helperPackage = try SNESPortableHelperPackage.load(directory: helpers)
            let verified = SNESFirmwareVerifiedInputs(backup: backup, helpers: helpers, candidate: candidate, helpersManifestSHA256: helperPackage.manifestSHA256,
                preflight: preflight, started: started, played: played, active: active, currentData: currentData)
            let material = try SNESFirmwareMaterial.install(verified: verified, recovery: inputs)
            try selectedEvidence?.requireSources(backup: material.source.source)
            try SNESColdBootPolicy.require(boot1: material.source.boot1, image: material.trial.image)
            let units = material.changedUnits.count
            guard (1...56).contains(units) else { throw SNESRuntimeBinding.failure() }
            let seal = try SNESFirmwareGuard.prepare(material, verified: verified)
            try seal.requireVerifiedInputs(verified, material: material); try selectedEvidence?.revalidate()
            let data = try SNESDataSnapshotPackage.load(receipt: currentData, source: material.source)
            let startupPlan = try material.planData()
            let review = try SNESFirstInstallOfflineReview(startupPlanSHA256: BackupManifest.digest(startupPlan),
                dataDirectory: data.directory, dataManifestSHA256: currentData.manifestSHA256, dataSHA256: data.sha256, dataBytes: data.byteCount)
            try data.revalidate()
            try seal.requireVerifiedInputs(verified, material: material); try selectedEvidence?.revalidate()
            try Task.checkCancellation()
            let store = try RecoveryBootSnapshotStore(root: backupRoot)
            let saved = try await store.saveSNESFirstInstallReview(review, startupPlan: startupPlan, verify: {
                try data.revalidate(); try seal.requireVerifiedInputs(verified, material: material); try selectedEvidence?.revalidate()
            })
            return SNESFirmwarePreparationReceipt(offlineReviewSHA256: try review.digest(), changedUnits: units, savedReview: saved)
        }
    }

    /// Prepare one stable Mac-only operation from the exact review selected.
    func prepareSNESReviewedConsoleCheck(review: SNESFirstInstallReviewReceipt) async throws -> SNESReviewedConsoleCheck {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before preparing a console check.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), rootProvider = firmwareJournalRoot
        return try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: review, recovery: inputs)
            let material = try selected.reviewedInstallMaterial(), checked = try SNESFirmwareGuard.prepare(material)
            try selected.revalidate(); try checked.require(material)
            let root = try rootProvider()
            let prepared = try SNESFirmwareJournal.prepare(material: material, root: root, guard: checked)
            return SNESReviewedConsoleCheck(operation: prepared.operation, planSHA256: prepared.reviewSHA256, review: review)
        }
    }

    /// Reopen a previously selected operation as a new review, not consent.
    func reopenSNESReviewedConsoleCheck(operation: URL, review: SNESFirstInstallReviewReceipt) async throws -> SNESReviewedConsoleCheck {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before selecting a saved console check.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), rootProvider = firmwareJournalRoot
        return try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: review, recovery: inputs)
            let root = try rootProvider(); try Self.requireSNESReviewedOperation(operation, root: root)
            let directory = try RestoreDirectory(operation), raw = try directory.read("plan.json", maximum: 65536)
            let digest = BackupManifest.digest(raw)
            let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: digest, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial()
                guard try await journal.phase() == .prepared, let binding = material.firstInstall,
                      binding.reviewDirectory == review.directory.path, binding.reviewSHA256 == review.sha256 else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate(); try await journal.close()
                return SNESReviewedConsoleCheck(operation: operation, planSHA256: digest, review: review)
            } catch { try? await journal.close(); throw error }
        }
    }

    /// Reopen the exact installation record on this Mac without retrying any operation.
    func reopenSNESReviewedInstallation(operation: URL, review: SNESFirstInstallReviewReceipt) async throws -> SNESReviewedInstallationRecord {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before checking a saved installation.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), rootProvider = firmwareJournalRoot
        return try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: review, recovery: inputs)
            let root = try rootProvider(); try Self.requireSNESReviewedOperation(operation, root: root)
            let directory = try RestoreDirectory(operation), raw = try directory.read("plan.json", maximum: 65536)
            let digest = BackupManifest.digest(raw)
            let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: digest, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial(), phase = try await journal.phase()
                guard let binding = material.firstInstall, binding.reviewDirectory == review.directory.path,
                      binding.reviewSHA256 == review.sha256 else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate(); try await journal.close()
                return SNESReviewedInstallationRecord(check: .init(operation: operation, planSHA256: digest, review: review), phase: phase)
            } catch { try? await journal.close(); throw error }
        }
    }

    /// Inspect an uncertain first or menu update without staging or writing firmware.
    func inspectSNESUncertainInstallation(after check: SNESReviewedConsoleCheck, upgrade: SNESReviewedUpgradeRecord? = nil,
                                          ready: Bool, progress: @escaping RecoveryProgressSink) async throws -> SNESFirmwareInspectionResult.Classification {
        guard ready, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open SNES setup and confirm the console is ready before checking it.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot(), makeIO = makeSNESActiveBoot2IO
        try Self.requireSNESReviewedOperation(check.operation, root: root)
        if let upgrade {
            try Self.requireSNESReviewedOperation(upgrade.upgrade.operation, root: root)
            if let parent = upgrade.parentMenu { try Self.requireSNESReviewedOperation(parent.operation, root: root) }
        }
        let (selected, journal, checked, io) = try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let operation = upgrade?.upgrade.operation ?? check.operation
            let digest = upgrade?.upgrade.reviewSHA256 ?? check.planSHA256
            let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: digest, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial(), phase = try await journal.phase()
                guard phase == .writeIntent || phase == .uncertain else { throw SNESRuntimeBinding.failure() }
                if let upgrade {
                    try Self.requireSNESMenuUpgradeMaterial(material, after: check, menu: upgrade.parentMenu)
                } else {
                    guard let binding = material.firstInstall, binding.reviewDirectory == check.review.directory.path,
                          binding.reviewSHA256 == check.review.sha256 else { throw SNESRuntimeBinding.failure() }
                }
                try selected.revalidate()
                let checked = try SNESFirmwareGuard.prepare(material)
                return (selected, journal, checked, makeIO(material.source, material.reader))
            } catch { try? await journal.close(); throw error }
        }
        do {
            try Task.checkCancellation(); try await checkRecoveryHost(); try Task.checkCancellation()
            await deviceManager.pauseForRecovery()
            defer { deviceManager.waitForNormalBootAfterRecovery() }
            let result = try await SNESFirmwareInspection().run(journal: journal, guard: checked, inputs: inputs, io: io, progress: progress)
            try selected.revalidate(); try await journal.close()
            return result.classification
        } catch { try? await journal.close(); throw error }
    }

    /// Prepare a restore record on the Mac; does not open USB or write firmware.
    func prepareSNESStartupRestore(operation: URL) async throws -> SNESPreparedStartupRestore {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before preparing a restore.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let rootProvider = firmwareJournalRoot
        let root = try rootProvider()
        try Self.requireSNESReviewedOperation(operation, root: root)
        let inputs = try await payloads.pinnedRecoveryInputs()
        return try await Self.runSNESRecoveryWorker {
            let directory = try RestoreDirectory(operation)
            let digest = BackupManifest.digest(try directory.read("plan.json", maximum: 65536))
            let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: digest, recovery: inputs)
            let parent: SNESFirmwareRestorableInstall
            do {
                parent = try await journal.restorableInstall()
                try await journal.close()
            } catch { try? await journal.close(); throw error }
            let material = try SNESFirmwareMaterial.restore(installed: parent)
            let checked = try SNESFirmwareGuard.prepare(material)
            let prepared = try SNESFirmwareJournal.prepare(material: material, root: root, guard: checked)
            return SNESPreparedStartupRestore(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, changedUnits: material.changedUnits.count,
                                              hasTestedWriter: material.writer.digest == SNESBoundedWriteHelper.sha256)
        }
    }

    /// Reopen a saved restore without authorizing or contacting a console.
    func openSNESStartupRestore(operation: URL) async throws -> SNESStartupRestoreRecord {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before opening a restore.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let root = try firmwareJournalRoot(); try Self.requireSNESReviewedOperation(operation, root: root)
        let inputs = try await payloads.pinnedRecoveryInputs()
        return try await Self.runSNESRecoveryWorker {
            let directory = try RestoreDirectory(operation)
            let digest = BackupManifest.digest(try directory.read("plan.json", maximum: 65536))
            let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: digest, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial(), phase = try await journal.phase()
                guard material.direction == .restore else { throw SNESRuntimeBinding.failure() }
                let restore = SNESPreparedStartupRestore(operation: operation, reviewSHA256: digest, changedUnits: material.changedUnits.count,
                                                         hasTestedWriter: material.writer.digest == SNESBoundedWriteHelper.sha256)
                try await journal.close()
                return SNESStartupRestoreRecord(restore: restore, phase: phase)
            } catch { try? await journal.close(); throw error }
        }
    }

    /// Record the user's normal-menu and game check after verified readback.
    func acceptSNESStartupRestore(_ restore: SNESPreparedStartupRestore, confirmed: Bool) async throws {
        guard confirmed, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Confirm the normal menu and a built-in game work first.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let root = try firmwareJournalRoot(); try Self.requireSNESReviewedOperation(restore.operation, root: root)
        let inputs = try await payloads.pinnedRecoveryInputs()
        try await Self.runSNESRecoveryWorker {
            let journal = try await SNESFirmwareJournal.reopen(operation: restore.operation, reviewSHA256: restore.reviewSHA256, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial()
                guard material.direction == .restore, try await journal.phase() == .readbackVerified else { throw SNESRuntimeBinding.failure() }
                try await journal.acceptMenu(); try await journal.close()
            } catch { try? await journal.close(); throw error }
        }
    }

    /// Check or restore a previously prepared original-startup record.
    func runSNESStartupRestore(_ restore: SNESPreparedStartupRestore, mode: SNESFirmwareTransaction.Mode,
                               ready: Bool, approved: Bool = false, progress: @escaping RecoveryProgressSink) async throws {
        guard ready, (mode != .write || approved), isPreparingSync, connectionConfig.lastConsoleType == .snesUsa,
              !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide and confirm the console is ready first.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), rootProvider = firmwareJournalRoot, makeIO = makeSNESFirmwareIO
        let (journal, checked, io) = try await Self.runSNESRecoveryWorker {
            let root = try rootProvider(); try Self.requireSNESReviewedOperation(restore.operation, root: root)
            let journal = try await SNESFirmwareJournal.reopen(operation: restore.operation, reviewSHA256: restore.reviewSHA256, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial()
                guard material.direction == .restore,
                      try await journal.phase() == (mode == .preflight ? .prepared : .preflightVerified) else { throw SNESRuntimeBinding.failure() }
                // Only the exact writer already used on a physical SNES is eligible here.
                if mode == .write, material.writer.digest != SNESBoundedWriteHelper.sha256 {
                    throw RecoveryProbeError.refused("This restore needs a startup tool that has not yet been verified on a console. No restore was started.")
                }
                let checked = try SNESFirmwareGuard.prepare(material)
                return (journal, checked, try makeIO(material, checked))
            } catch { try? await journal.close(); throw error }
        }
        var transactionStarted = false
        do {
            try Task.checkCancellation(); try await checkRecoveryHost(); try Task.checkCancellation()
            await deviceManager.pauseForRecovery()
            defer { deviceManager.waitForNormalBootAfterRecovery() }
            transactionStarted = true
            _ = try await SNESFirmwareTransaction().run(mode: mode, journal: journal, guard: checked, inputs: inputs, io: io, progress: progress)
            try await journal.close()
        } catch {
            let phase = try? await journal.phase()
            try? await journal.close()
            throw SNESFirmwareOutcomeFailure.classify(error, mode: mode, transactionStarted: transactionStarted, phase: phase)
        }
    }

    /// Run the temporary comparison only after the user confirms recovery mode.
    func runSNESReviewedConsoleCheck(_ check: SNESReviewedConsoleCheck, ready: Bool, progress: @escaping RecoveryProgressSink) async throws {
        try await runSNESReviewedOperation(check, mode: .preflight, ready: ready, progress: progress)
    }

    /// The install requires both readiness and a separate explicit user approval.
    func runSNESReviewedInstallation(_ check: SNESReviewedConsoleCheck, ready: Bool, approved: Bool, progress: @escaping RecoveryProgressSink) async throws {
        guard ready, approved else { throw RecoveryProbeError.refused("Confirm that the SNES is ready and approve the installation first.") }
        try await runSNESReviewedOperation(check, mode: .write, ready: ready, progress: progress)
    }

    private func runSNESReviewedOperation(_ check: SNESReviewedConsoleCheck, mode: SNESFirmwareTransaction.Mode,
                                          ready: Bool, progress: @escaping RecoveryProgressSink) async throws {
        guard ready, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide and confirm the console is in recovery mode first.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), rootProvider = firmwareJournalRoot, makeIO = makeSNESFirmwareIO
        let (journal, checked, io) = try await Self.runSNESRecoveryWorker {
            let root = try rootProvider(); try Self.requireSNESReviewedOperation(check.operation, root: root)
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: check.operation, reviewSHA256: check.planSHA256, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial()
                guard try await journal.phase() == .prepared, let binding = material.firstInstall,
                      binding.reviewDirectory == check.review.directory.path, binding.reviewSHA256 == check.review.sha256 else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate()
                let checked = try SNESFirmwareGuard.prepare(material)
                return (journal, checked, try makeIO(material, checked))
            } catch { try? await journal.close(); throw error }
        }
        var transactionStarted = false
        do {
            try Task.checkCancellation()
            try await checkRecoveryHost()
            try Task.checkCancellation()
            await deviceManager.pauseForRecovery()
            defer { deviceManager.waitForNormalBootAfterRecovery() }
            transactionStarted = true
            _ = try await SNESFirmwareTransaction().run(mode: mode, journal: journal, guard: checked, inputs: inputs, io: io, progress: progress)
            try await journal.close()
        } catch {
            let phase = try? await journal.phase()
            try? await journal.close()
            throw SNESFirmwareOutcomeFailure.classify(error, mode: mode, transactionStarted: transactionStarted, phase: phase)
        }
    }

    /// Verify a normally booted installation before asking the user to test a game.
    func checkSNESReviewedInstallation(_ check: SNESReviewedConsoleCheck, ready: Bool) async throws {
        guard ready, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Return the SNES to its normal game menu before checking it.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), rootProvider = firmwareJournalRoot, makeIO = makeSNESInstalledStartupIO
        let (journal, checked, io) = try await Self.runSNESRecoveryWorker {
            let root = try rootProvider(); try Self.requireSNESReviewedOperation(check.operation, root: root)
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: check.operation, reviewSHA256: check.planSHA256, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial()
                _ = try SNESInstalledStartupCheck.recordStartupTransition(for: await journal.phase())
                guard let binding = material.firstInstall,
                      binding.reviewDirectory == check.review.directory.path, binding.reviewSHA256 == check.review.sha256 else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate()
                return (journal, try SNESFirmwareGuard.prepare(material), try makeIO(material.trial))
            } catch { try? await journal.close(); throw error }
        }
        do {
            try Task.checkCancellation(); try await checkRecoveryHost(); try Task.checkCancellation()
            await deviceManager.pauseForRecovery()
            defer { deviceManager.resumeAfterExclusive() }
            _ = try await SNESInstalledStartupCheck().run(journal: journal, guard: checked, io: io)
            try await journal.close()
        } catch { try? await journal.close(); throw error }
    }

    /// Accept the installation only after the normal startup check and user game test.
    func acceptSNESReviewedInstallation(_ check: SNESReviewedConsoleCheck, confirmed: Bool) async throws {
        guard confirmed, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Confirm the SNES menu and a built-in game work first.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot()
        try Self.requireSNESReviewedOperation(check.operation, root: root)
        try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: check.operation, reviewSHA256: check.planSHA256, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial()
                guard try await journal.phase() == .startupVerified, let binding = material.firstInstall,
                      binding.reviewDirectory == check.review.directory.path, binding.reviewSHA256 == check.review.sha256 else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate(); try await journal.acceptMenu(); try await journal.close()
            } catch { try? await journal.close(); throw error }
        }
    }

    /// Prepare the next menu-capable startup on the Mac after confirmed installation.
    func prepareSNESMenuStartup(after check: SNESReviewedConsoleCheck, currentData: SNESDataSnapshotReceipt? = nil) async throws -> SNESSetupRecordReceipt {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before preparing its game menu.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot(), backupRoot = snesBackupsDirectory
        try Self.requireSNESReviewedOperation(check.operation, root: root)
        return try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: check.operation, reviewSHA256: check.planSHA256, recovery: inputs)
            let parent: SNESMenuStartupParent
            do {
                let material = try await journal.verifiedMaterial()
                guard try await journal.phase() == .menuAccepted, let binding = material.firstInstall,
                      binding.reviewDirectory == check.review.directory.path, binding.reviewSHA256 == check.review.sha256 else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate(); let reviewed = SNESDataSnapshotReceipt(directory: selected.data.directory, manifestSHA256: selected.data.manifestSHA256)
                parent = try await journal.menuStartupParent(currentData: currentData ?? reviewed); try await journal.close()
            } catch { try? await journal.close(); throw error }
            try selected.revalidate(); try parent.validate()
            let store = try RecoveryBootSnapshotStore(root: backupRoot)
            try await store.checkWritableDestination()
            return try await store.saveSNESStartupCandidateWithReceipt(parent.candidate, verify: { directory in
                let saved = try SNESStartupAdapterCandidate.load(directory: directory)
                try parent.require(saved); try selected.revalidate()
            })
        }
    }

    /// Save a fresh read-only data backup for an already confirmed first installation.
    func backupSNESReviewedCurrentData(after check: SNESReviewedConsoleCheck, ready: Bool,
                                       progress: @escaping RecoveryProgressSink) async throws -> SNESDataSnapshotReceipt {
        guard ready, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open SNES setup and confirm the console is ready before making its backup.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot(), backupRoot = snesBackupsDirectory
        let makeIO = makeSNESDataSnapshotIO
        try Self.requireSNESReviewedOperation(check.operation, root: root)
        let (selected, parent, source, store) = try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: check.operation, reviewSHA256: check.planSHA256, recovery: inputs)
            let parent: SNESMenuStartupParent
            do {
                let material = try await journal.verifiedMaterial()
                guard try await journal.phase() == .menuAccepted, let binding = material.firstInstall,
                      binding.reviewDirectory == check.review.directory.path, binding.reviewSHA256 == check.review.sha256 else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate()
                parent = try await journal.menuStartupParent(currentData: .init(directory: selected.data.directory, manifestSHA256: selected.data.manifestSHA256))
                try await journal.close()
            } catch { try? await journal.close(); throw error }
            let source = try SNESPreparationSource.load(parent.candidate.material.support.setup)
            let store = try RecoveryBootSnapshotStore(root: backupRoot)
            try await store.checkWritableDestination()
            let plan = try source.dataSnapshotPlan()
            guard let available = try SNESBackupCapacity.available(at: backupRoot), available >= Int64(plan.byteCount) + 32 * 1024 * 1024 else {
                throw RecoveryProbeError.refused("This Mac needs more free space for the console backup. Nothing was changed on the SNES.")
            }
            try selected.revalidate(); try parent.validate(); try source.revalidate()
            return (selected, parent, source, store)
        }
        _ = try inputs.prepare(); try Task.checkCancellation(); try await checkRecoveryHost(); try Task.checkCancellation()
        try await Self.runSNESRecoveryWorker { try selected.revalidate(); try parent.validate(); try source.revalidate() }
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let captured = try await SNESDataSnapshotService().captureAndSave(source: source, inputs: inputs, io: makeIO(source), progress: progress,
            detail: { _ in }, save: { result in
                try await store.saveSNESDataSnapshotWithReceipt(result, verify: { _ in
                    try selected.revalidate(); try parent.validate(); try source.revalidate()
                })
            })
        return captured.backup
    }

    /// Prepare the game-folder startup after the installed menu was confirmed.
    func prepareSNESLibraryStartup(after check: SNESReviewedConsoleCheck, menu: SNESFirmwareJournal.Prepared,
                                   currentData: SNESDataSnapshotReceipt? = nil, confirmed: Bool) async throws -> SNESSetupRecordReceipt {
        guard confirmed, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Confirm the SNES menu and a built-in game work before preparing its game folders.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot(), backupRoot = snesBackupsDirectory
        try Self.requireSNESReviewedOperation(check.operation, root: root); try Self.requireSNESReviewedOperation(menu.operation, root: root)
        return try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: menu.operation, reviewSHA256: menu.reviewSHA256, recovery: inputs)
            let parent: SNESMenuStartupParent
            do {
                let material = try await journal.verifiedMaterial()
                try Self.requireSNESMenuUpgradeMaterial(material, after: check)
                guard try await journal.phase() == .menuAccepted else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate(); parent = try await journal.libraryStartupParent(currentData: currentData); try await journal.close()
            } catch { try? await journal.close(); throw error }
            try selected.revalidate(); try parent.validate()
            let store = try RecoveryBootSnapshotStore(root: backupRoot); try await store.checkWritableDestination()
            return try await store.saveSNESStartupCandidateWithReceipt(parent.candidate, verify: { directory in
                let saved = try SNESStartupAdapterCandidate.load(directory: directory)
                try parent.require(saved); try selected.revalidate()
            })
        }
    }

    /// Compare the accepted installation and the menu files without writing firmware.
    func checkSNESMenuStartup(after check: SNESReviewedConsoleCheck, menu: SNESFirmwareJournal.Prepared? = nil, candidate: SNESSetupRecordReceipt,
                              ready: Bool, progress: @escaping RecoveryProgressSink) async throws -> SNESStartupPreflightReceipt {
        guard ready, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide and confirm the console is ready first.")
        }
        guard candidate.kind == .candidate, SNESDataSnapshotChunk.isDigest(candidate.manifestSHA256) else { throw SNESRuntimeBinding.failure() }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot(), backupRoot = snesBackupsDirectory
        let makeIO = makeSNESMenuStartupPreflightIO
        try Self.requireSNESReviewedOperation(check.operation, root: root)
        let (parent, saved, selected, store, io) = try await Self.runSNESRecoveryWorker {
            let saved = try SNESStartupAdapterCandidate.load(directory: candidate.directory, expectedManifestSHA256: candidate.manifestSHA256)
            let (selected, parent) = try await Self.snesStartupParent(check: check, menu: menu, candidate: saved, recovery: inputs, root: root)
            let store = try RecoveryBootSnapshotStore(root: backupRoot); try await store.checkWritableDestination()
            return (parent, saved, selected, store, try makeIO(saved, parent))
        }
        try Task.checkCancellation(); try await checkRecoveryHost(); try Task.checkCancellation()
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let result = try await SNESStartupPreflightService().capture(candidate: saved, inputs: inputs, io: io, progress: progress, parent: parent)
        return try await Self.runSNESRecoveryWorker {
            try parent.validate(); try selected.revalidate()
            return try await store.saveSNESStartupPreflightWithReceipt(result, verify: { _ in
                try parent.validate(); try selected.revalidate()
            })
        }
    }

    /// Start or check the temporary menu startup using its accepted parent and exact receipts.
    func runSNESMenuStartupTrial(after check: SNESReviewedConsoleCheck, menu: SNESFirmwareJournal.Prepared? = nil, candidate: SNESSetupRecordReceipt,
                                 preflight: SNESStartupPreflightReceipt, started: SNESSetupRecordReceipt? = nil,
                                 ready: Bool, progress: @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt {
        guard ready, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide and confirm the console is ready first.")
        }
        guard candidate.kind == .candidate, preflight.record.kind == .preflight,
              started == nil || started?.kind == .trialStarted else { throw SNESRuntimeBinding.failure() }
        guard preflight.backupMatches else {
            throw RecoveryProbeError.refused("The SNES data changed since its backup. Make a new backup before continuing. Nothing was installed.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot(), backupRoot = snesBackupsDirectory
        let makeIO = makeSNESStartupTrialIO
        try Self.requireSNESReviewedOperation(check.operation, root: root)
        let (parent, selected, trial, earlier, store) = try await Self.runSNESRecoveryWorker {
            let saved = try SNESStartupAdapterCandidate.load(directory: candidate.directory, expectedManifestSHA256: candidate.manifestSHA256)
            let (selected, parent) = try await Self.snesStartupParent(check: check, menu: menu, candidate: saved, recovery: inputs, root: root)
            let trial = try PreparedSNESStartupTrial.prepare(candidate: saved, receipt: preflight, recovery: inputs, parent: parent)
            let earlier = try started.map { try SNESStartupTrialResult.loadStarted(receipt: $0, trial: trial) }
            let store = try RecoveryBootSnapshotStore(root: backupRoot); try await store.checkWritableDestination()
            return (parent, selected, trial, earlier, store)
        }
        let validate: @Sendable () throws -> Void = {
            try Self.requireSavedSNESCandidate(candidate, image: trial.image); try selected.revalidate(); try parent.require(trial.candidate)
            try trial.evidence.requireReceipt(preflight, candidate: trial.candidate)
            if let started { guard let earlier else { throw SNESRuntimeBinding.failure() }; try earlier.requireSavedReceipt(started) }
        }
        try Task.checkCancellation(); try await checkRecoveryHost(); try await Self.runSNESRecoveryWorker { try validate() }
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        let io = try makeIO(trial)
        do {
            let result = try await SNESStartupTrialService().capture(trial: trial, started: earlier, io: io, progress: progress, validateInputs: validate)
            if let started { return try await store.saveSNESStartupTrialPlayedWithReceipt(result, trial: trial, started: started, verify: { _ in try validate() }) }
            return try await store.saveSNESStartupTrialStartedWithReceipt(result, trial: trial, verify: { _ in try validate() })
        } catch let failure as SNESStartupTrialFailure {
            let directory = try await store.saveSNESStartupTrialFailure(failure, trial: trial)
            throw SNESPreparationDiagnosticSavedError(directory: directory)
        }
    }

    /// Prepare a menu upgrade on the Mac after the temporary test was confirmed.
    func prepareSNESMenuUpgrade(after check: SNESReviewedConsoleCheck, menu: SNESFirmwareJournal.Prepared? = nil, candidate: SNESSetupRecordReceipt,
                                preflight: SNESStartupPreflightReceipt, started: SNESSetupRecordReceipt,
                                played: SNESSetupRecordReceipt, confirmed: Bool) async throws -> SNESFirmwareJournal.Prepared {
        guard confirmed, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Confirm the temporary menu and game work before preparing the update.")
        }
        guard candidate.kind == .candidate, preflight.record.kind == .preflight,
              started.kind == .trialStarted, played.kind == .trialPlayed else { throw SNESRuntimeBinding.failure() }
        guard preflight.backupMatches else {
            throw RecoveryProbeError.refused("The SNES data changed since its backup. Make a new backup before continuing. Nothing was installed.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot()
        try Self.requireSNESReviewedOperation(check.operation, root: root)
        return try await Self.runSNESRecoveryWorker {
            let saved = try SNESStartupAdapterCandidate.load(directory: candidate.directory, expectedManifestSHA256: candidate.manifestSHA256)
            let (selected, parent) = try await Self.snesStartupParent(check: check, menu: menu, candidate: saved, recovery: inputs, root: root)
            let trial = try PreparedSNESStartupTrial.prepare(candidate: saved, receipt: preflight, recovery: inputs, parent: parent)
            let proof = try SNESFirmwareTrialProof.load(started: started.directory, played: played.directory, trial: trial,
                expectedStartedSHA256: started.manifestSHA256, expectedPlayedSHA256: played.manifestSHA256)
            let original = parent.installed.paths
            let paths = SNESFirmwarePaths(candidate: candidate.directory.path, preflight: preflight.record.directory.path,
                started: started.directory.path, played: played.directory.path, original: original.original, reader: original.reader, writer: original.writer)
            let material = try SNESFirmwareMaterial.upgrade(parent: parent, paths: paths, recovery: inputs)
            try SNESColdBootPolicy.require(boot1: material.source.boot1, image: material.trial.image)
            let checked = try SNESFirmwareGuard.prepare(material)
            return try SNESFirmwareJournal.prepare(material: material, root: root, guard: checked, verifyFinal: {
                try selected.revalidate(); try parent.require(saved); try trial.evidence.requireReceipt(preflight, candidate: saved)
                try proof.revalidate(trial: trial); try checked.require(material)
            })
        }
    }

    /// Inspect a saved menu or game-folder update without starting a console operation.
    func reopenSNESMenuUpgrade(operation: URL, after check: SNESReviewedConsoleCheck,
                               menu: SNESFirmwareJournal.Prepared? = nil) async throws -> SNESReviewedUpgradeRecord {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before checking a saved update.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot()
        try Self.requireSNESReviewedOperation(check.operation, root: root); try Self.requireSNESReviewedOperation(operation, root: root)
        if let menu { try Self.requireSNESReviewedOperation(menu.operation, root: root) }
        return try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let directory = try RestoreDirectory(operation), digest = BackupManifest.digest(try directory.read("plan.json", maximum: 65536))
            let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: digest, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial(), phase = try await journal.phase()
                guard let parent = material.trial.evidence.parent else { throw SNESRuntimeBinding.failure() }
                let parentRecord = SNESFirmwareJournal.Prepared(operation: parent.directory, reviewSHA256: parent.record.reviewSHA256)
                let inferred = try Self.resolveSNESUpgradeParent(parentRecord, after: check, supplied: menu, root: root)
                try Self.requireSNESMenuUpgradeMaterial(material, after: check, menu: inferred)
                try selected.revalidate(); try await journal.close()
                return SNESReviewedUpgradeRecord(upgrade: .init(operation: operation, reviewSHA256: digest), parentMenu: inferred, phase: phase)
            } catch { try? await journal.close(); throw error }
        }
    }

    /// Check or run the saved menu update after explicit readiness and approval.
    func runSNESMenuUpgrade(_ upgrade: SNESFirmwareJournal.Prepared, after check: SNESReviewedConsoleCheck, menu: SNESFirmwareJournal.Prepared? = nil,
                            mode: SNESFirmwareTransaction.Mode, ready: Bool, approved: Bool = false,
                            progress: @escaping RecoveryProgressSink) async throws {
        guard ready, (mode != .write || approved), isPreparingSync, connectionConfig.lastConsoleType == .snesUsa,
              !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide and confirm the console is ready first.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot(), makeIO = makeSNESFirmwareIO
        try Self.requireSNESReviewedOperation(check.operation, root: root)
        try Self.requireSNESReviewedOperation(upgrade.operation, root: root)
        if let menu { try Self.requireSNESReviewedOperation(menu.operation, root: root) }
        let (journal, checked, io) = try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: upgrade.operation, reviewSHA256: upgrade.reviewSHA256, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial()
                try Self.requireSNESMenuUpgradeMaterial(material, after: check, menu: menu)
                guard try await journal.phase() == (mode == .preflight ? .prepared : .preflightVerified) else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate()
                let checked = try SNESFirmwareGuard.prepare(material)
                return (journal, checked, try makeIO(material, checked))
            } catch { try? await journal.close(); throw error }
        }
        var transactionStarted = false
        do {
            try Task.checkCancellation(); try await checkRecoveryHost(); try Task.checkCancellation()
            await deviceManager.pauseForRecovery()
            defer { deviceManager.waitForNormalBootAfterRecovery() }
            transactionStarted = true
            _ = try await SNESFirmwareTransaction().run(mode: mode, journal: journal, guard: checked, inputs: inputs, io: io, progress: progress)
            try await journal.close()
        } catch {
            let phase = try? await journal.phase(); try? await journal.close()
            throw SNESFirmwareOutcomeFailure.classify(error, mode: mode, transactionStarted: transactionStarted, phase: phase)
        }
    }

    func checkSNESMenuUpgrade(_ upgrade: SNESFirmwareJournal.Prepared, after check: SNESReviewedConsoleCheck, menu: SNESFirmwareJournal.Prepared? = nil, ready: Bool) async throws {
        guard ready, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Return the SNES to its normal game menu before checking it.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot(), makeIO = makeSNESInstalledStartupIO
        try Self.requireSNESReviewedOperation(check.operation, root: root); try Self.requireSNESReviewedOperation(upgrade.operation, root: root)
        if let menu { try Self.requireSNESReviewedOperation(menu.operation, root: root) }
        let (journal, checked, io) = try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: upgrade.operation, reviewSHA256: upgrade.reviewSHA256, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial()
                try Self.requireSNESMenuUpgradeMaterial(material, after: check, menu: menu)
                _ = try SNESInstalledStartupCheck.recordStartupTransition(for: await journal.phase())
                try selected.revalidate()
                return (journal, try SNESFirmwareGuard.prepare(material), try makeIO(material.trial))
            } catch { try? await journal.close(); throw error }
        }
        do {
            try Task.checkCancellation(); try await checkRecoveryHost(); try Task.checkCancellation()
            await deviceManager.pauseForRecovery()
            defer { deviceManager.resumeAfterExclusive() }
            _ = try await SNESInstalledStartupCheck().run(journal: journal, guard: checked, io: io)
            try await journal.close()
        } catch { try? await journal.close(); throw error }
    }

    func acceptSNESMenuUpgrade(_ upgrade: SNESFirmwareJournal.Prepared, after check: SNESReviewedConsoleCheck, menu: SNESFirmwareJournal.Prepared? = nil, confirmed: Bool) async throws {
        guard confirmed, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Confirm the SNES menu and a built-in game work first.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot()
        try Self.requireSNESReviewedOperation(check.operation, root: root); try Self.requireSNESReviewedOperation(upgrade.operation, root: root)
        if let menu { try Self.requireSNESReviewedOperation(menu.operation, root: root) }
        try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: upgrade.operation, reviewSHA256: upgrade.reviewSHA256, recovery: inputs)
            do {
                let material = try await journal.verifiedMaterial()
                try Self.requireSNESMenuUpgradeMaterial(material, after: check, menu: menu)
                guard try await journal.phase() == .startupVerified else { throw SNESRuntimeBinding.failure() }
                try selected.revalidate(); try await journal.acceptMenu(); try await journal.close()
            } catch { try? await journal.close(); throw error }
        }
    }

    /// Save the included-game catalog from the normally running, confirmed folder startup.
    func captureSNESReviewedOriginalGames(_ upgrade: SNESFirmwareJournal.Prepared, after check: SNESReviewedConsoleCheck,
                                          menu: SNESFirmwareJournal.Prepared, ready: Bool,
                                          makeIO: @escaping @Sendable (PreparedSNESStartupTrial) -> any SNESOriginalGamesIO = { NativeSNESOriginalGamesIO(trial: $0) }) async throws -> URL {
        guard ready, isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open SNES setup and leave the console at its game menu before checking its included games.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs(), root = try firmwareJournalRoot(), backupRoot = snesBackupsDirectory
        try Self.requireSNESReviewedOperation(check.operation, root: root)
        try Self.requireSNESReviewedOperation(menu.operation, root: root)
        try Self.requireSNESReviewedOperation(upgrade.operation, root: root)
        let (selected, journal, accepted, checked, store) = try await Self.runSNESRecoveryWorker {
            let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: inputs)
            let journal = try await SNESFirmwareJournal.reopen(operation: upgrade.operation, reviewSHA256: upgrade.reviewSHA256, recovery: inputs)
            do {
                let accepted = try await journal.acceptedInstall()
                try Self.requireSNESMenuUpgradeMaterial(accepted.material, after: check, menu: menu)
                guard accepted.material.trial.candidate.hasNativeArtworkSupport else { throw SNESRuntimeBinding.failure() }
                let checked = try SNESFirmwareGuard.prepare(accepted.material)
                try selected.revalidate(); try checked.require(accepted.material)
                let store = try RecoveryBootSnapshotStore(root: backupRoot); try await store.checkWritableDestination()
                return (selected, journal, accepted, checked, store)
            } catch { try? await journal.close(); throw error }
        }
        do {
            try Task.checkCancellation(); try await checkRecoveryHost(); try Task.checkCancellation()
            await deviceManager.pauseForRecovery()
            defer { deviceManager.resumeAfterExclusive() }
            let result = try await SNESOriginalGamesCapture().capture(accepted: accepted, guard: checked, io: makeIO(accepted.material.trial))
            _ = try await journal.acceptedInstall(); try checked.require(accepted.material); try selected.revalidate()
            let directory = try await store.saveSNESOriginalGames(result)
            _ = try await Self.runSNESRecoveryWorker { try SNESOriginalGamesPackage.load(directory: directory, accepted: accepted) }
            _ = try await journal.acceptedInstall(); try checked.require(accepted.material); try selected.revalidate()
            try await journal.close()
            return directory
        } catch { try? await journal.close(); throw error }
    }

    /// Reconstruct the accepted parent for either the menu or game-folder startup.
    nonisolated private static func snesStartupParent(check: SNESReviewedConsoleCheck, menu: SNESFirmwareJournal.Prepared?,
                                                     candidate: SNESStartupAdapterCandidate, recovery: RecoveryBootInputs,
                                                     root: URL) async throws -> (SNESFirstInstallReviewMaterial, SNESMenuStartupParent) {
        try requireSNESReviewedOperation(check.operation, root: root)
        if let menu { try requireSNESReviewedOperation(menu.operation, root: root) }
        let selected = try SNESFirstInstallReviewMaterial.load(receipt: check.review, recovery: recovery)
        let operation = menu?.operation ?? check.operation, digest = menu?.reviewSHA256 ?? check.planSHA256
        let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: digest, recovery: recovery)
        let parent: SNESMenuStartupParent
        do {
            let material = try await journal.verifiedMaterial()
            guard try await journal.phase() == .menuAccepted else { throw SNESRuntimeBinding.failure() }
            let currentData = SNESDataSnapshotReceipt(directory: candidate.backup.directory, manifestSHA256: candidate.backup.manifestSHA256)
            if menu != nil {
                try requireSNESMenuUpgradeMaterial(material, after: check)
                parent = try await journal.libraryStartupParent(currentData: currentData)
            } else {
                guard let binding = material.firstInstall, binding.reviewDirectory == check.review.directory.path,
                      binding.reviewSHA256 == check.review.sha256 else { throw SNESRuntimeBinding.failure() }
                parent = try await journal.menuStartupParent(currentData: currentData)
            }
            try selected.revalidate(); try await journal.close()
        } catch { try? await journal.close(); throw error }
        try parent.require(candidate); try selected.revalidate(); return (selected, parent)
    }

    nonisolated private static func requireSNESMenuUpgradeMaterial(_ material: SNESFirmwareMaterial, after check: SNESReviewedConsoleCheck,
                                                                   menu: SNESFirmwareJournal.Prepared? = nil) throws {
        guard material.direction == .install, let parent = material.trial.evidence.parent else { throw SNESRuntimeBinding.failure() }
        let initial: SNESMenuStartupParent
        if let menu {
            guard parent.directory.path == menu.operation.path, parent.record.reviewSHA256 == menu.reviewSHA256,
                  let ancestor = parent.installed.trial.evidence.parent else { throw SNESRuntimeBinding.failure() }
            try ancestor.require(parent.installed.trial.candidate); initial = ancestor
        } else { initial = parent }
        guard initial.directory.path == check.operation.path, initial.record.reviewSHA256 == check.planSHA256,
              let binding = initial.installed.firstInstall, binding.reviewDirectory == check.review.directory.path,
              binding.reviewSHA256 == check.review.sha256 else { throw SNESRuntimeBinding.failure() }
        try parent.require(material.trial.candidate)
    }

    nonisolated static func resolveSNESUpgradeParent(_ parent: SNESFirmwareJournal.Prepared, after check: SNESReviewedConsoleCheck,
                                                     supplied: SNESFirmwareJournal.Prepared?, root: URL) throws -> SNESFirmwareJournal.Prepared? {
        try requireSNESReviewedOperation(check.operation, root: root); try requireSNESReviewedOperation(parent.operation, root: root)
        guard SNESDataSnapshotChunk.isDigest(parent.reviewSHA256) else { throw SNESRuntimeBinding.failure() }
        if parent.operation.path == check.operation.path {
            guard parent.reviewSHA256 == check.planSHA256, supplied == nil else { throw SNESRuntimeBinding.failure() }
            return nil
        }
        if let supplied {
            guard supplied.operation.path == parent.operation.path, supplied.reviewSHA256 == parent.reviewSHA256 else { throw SNESRuntimeBinding.failure() }
        }
        return parent
    }

    nonisolated private static func requireSNESReviewedOperation(_ operation: URL, root: URL) throws {
        let prefix = "SNESFirmware-", name = operation.lastPathComponent
        guard operation.isFileURL, root.isFileURL, operation == operation.standardizedFileURL,
              root == root.standardizedFileURL, operation.deletingLastPathComponent().path == root.path,
              name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { throw SNESRuntimeBinding.failure() }
    }

    /// Recheck a user-selected draft on this Mac; does not connect to the console or authorize installation.
    func inspectSNESFirstInstallReview(directory: URL) async throws -> SNESFirstInstallReviewSummary {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa, !taskRunner.isRunning, !snesTrialInProgress else {
            throw RecoveryProbeError.refused("Open the SNES setup guide before checking a saved review.")
        }
        snesTrialInProgress = true; defer { snesTrialInProgress = false }
        let inputs = try await payloads.pinnedRecoveryInputs()
        return try await Self.runSNESRecoveryWorker {
            let receipt = try SNESFirstInstallReviewReceipt.inspect(directory: directory)
            let review = try SNESFirstInstallReviewMaterial.load(receipt: receipt, recovery: inputs)
            try review.revalidate()
            return SNESFirstInstallReviewSummary(reviewDirectory: receipt.directory,
                dataDirectory: review.data.directory, reviewSHA256: receipt.sha256, changedUnits: review.changedUnits)
        }
    }

    var snesBackupsDirectory: URL { connectionConfig.workspace.backups }

    nonisolated static func runSNESRecoveryWorker<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try await operation()
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private func captureSNES(progress: @escaping RecoveryProgressSink, includeSetupEvidence: Bool) async throws -> SNESSavedCapture {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa,
              !taskRunner.isRunning else { throw RecoveryProbeError.refused("Select the US SNES library and open Prepare SNES Setup first.") }
        guard !snesTrialInProgress else { throw RecoveryProbeError.refused("Another SNES setup operation is already running.") }
        snesTrialInProgress = true
        defer { snesTrialInProgress = false }
        try await checkRecoveryHost()
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        await progress(.checkingMaterial)
        let root = connectionConfig.workspace.backups
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try RecoveryBootSnapshotStore(root: root)
        let inputs = try await payloads.pinnedRecoveryInputs()
        let io = NativeRecoveryProbeIO(observationCommand: SNESBackupPolicy.command)
        let saved: SNESSavedCapture
        if includeSetupEvidence {
            do {
                let report = try await SNESSetupReadinessService().capture(inputs: inputs, io: io, progress: progress)
                saved = .setup(try await store.saveSNESSetupWithReceipt(report))
            } catch let failure as SNESSetupDiagnosticFailure {
                let directory = try await store.saveSNESSetupDiagnostic(failure)
                throw SNESSetupDiagnosticSavedError(directory: directory)
            }
        } else {
            let report = try await SNESKernelBackupService().capture(inputs: inputs, io: io, progress: progress)
            saved = .kernel(try await store.saveSNES(report))
        }
        gameManager.clearConsoleGames()
        connectionConfig.lastConsoleType = .snesUsa
        connectionConfig.lastDeviceId = ""; connectionConfig.installedGameCodes = []
        saveConnectionConfiguration()
        selectedGame = nil; searchText = ""; preparedPlan = nil; preparedInventory = nil; legacyCapacityPreview = nil
        gameManager.loadGames()
        statusMessage = "SNES backup saved on this Mac. Return the console to normal boot."
        return saved
    }

    // MARK: - Flash operations

    /// Request a flash operation. For install, shows config sheet first.
    /// If FEL is required but not present, shows the waiting dialog.
    func requestFlash(_ operation: FlashOperation) {
        guard deviceManager.legacyReport == nil else {
            reportOperationError("Legacy Clovershell is connected for limited game management. Firmware operations remain unavailable.")
            return
        }
        guard !taskRunner.isRunning, !isPreparingSync else { return }
        guard operation == .dumpStockKernel else {
            reportOperationError("Firmware installation and recovery are retained from upstream and will be enabled after separate device validation. This first milestone manages an already-modified NES.")
            return
        }
        logger.info("Flash requested: \(String(describing: operation))")
        pendingFlashOperation = operation

        // Suppress auto-connect immediately — we need the USB device for FEL
        if operation.requiresFEL {
            deviceManager.suppressAutoConnect = true
        }

        // Install gets a config sheet first (backup settings)
        if operation == .installHakchi {
            showInstallConfig = true
            return
        }

        // Factory reset needs a stock kernel image to flash back
        if operation == .factoryReset {
            pickKernelImage { [weak self] kernelData in
                guard let self else { return }
                self.pendingKernelImage = kernelData

                if !self.deviceManager.felDevicePresent {
                    logger.info("FEL device not present, showing waiting dialog")
                    self.showWaitingForDevice = true
                    return
                }
                self.startFlashOperation(operation)
            }
            return
        }

        if operation.requiresFEL && !deviceManager.felDevicePresent {
            logger.info("FEL device not present, showing waiting dialog")
            showWaitingForDevice = true
            return
        }

        startFlashOperation(operation)
    }

    /// Called when user confirms install from the config sheet
    func confirmInstall(backupSettings: BackupSettings) {
        logger.info("Install confirmed, backup: \(backupSettings.enabled)")
        pendingBackupSettings = backupSettings
        showInstallConfig = false

        guard let operation = pendingFlashOperation else { return }
        if operation.requiresFEL && !deviceManager.felDevicePresent {
            logger.info("FEL device not present, showing waiting dialog")
            showWaitingForDevice = true
            return
        }

        startFlashOperation(operation)
    }

    /// Called when user cancels the install config sheet
    func cancelInstallConfig() {
        logger.info("User cancelled install config")
        pendingFlashOperation = nil
        pendingBackupSettings = nil
        showInstallConfig = false
        deviceManager.suppressAutoConnect = false
    }

    /// Called when user cancels the waiting dialog
    func cancelWaitingForDevice() {
        logger.info("User cancelled waiting for device")
        pendingFlashOperation = nil
        pendingBackupSettings = nil
        pendingKernelImage = nil
        showWaitingForDevice = false
        deviceManager.suppressAutoConnect = false
    }

    /// Show a file picker for the stock kernel image.
    /// Defaults to the dump directory where we save backups.
    private func pickKernelImage(completion: @escaping (Data?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Stock Kernel Backup"
        panel.message = "Choose the kernel_backup.img file saved during install"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = AppConfig.shared.dumpDirectory

        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else {
                    logger.info("User cancelled kernel image picker")
                    self.pendingFlashOperation = nil
                    self.deviceManager.suppressAutoConnect = false
                    return
                }

                guard let data = try? Data(contentsOf: url) else {
                    logger.error("Failed to read kernel image from \(url.path)")
                    self.pendingFlashOperation = nil
                    self.deviceManager.suppressAutoConnect = false
                    return
                }

                logger.info("Kernel image selected: \(url.lastPathComponent) (\(data.count) bytes)")
                completion(data)
            }
        }
    }

    /// Actually start the flash operation (FEL device is confirmed present)
    private func startFlashOperation(_ operation: FlashOperation) {
        logger.info("Starting flash operation: \(String(describing: operation))")
        showTaskProgress = true

        // Suppress auto-connect while flash is in progress
        deviceManager.suppressAutoConnect = true

        let flashService = FlashService(
            felService: deviceManager.felService,
            deviceManager: deviceManager
        )

        switch operation {
        case .installHakchi:
            let backupSettings = pendingBackupSettings ?? BackupSettings(enabled: true, directory: nil)
            pendingBackupSettings = nil

            taskRunner.run(name: "Installing custom kernel") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }

                runner.updateProgress(status: "Loading payloads...", fraction: 0.01)
                let fes1 = try await self.payloads.fes1()
                runner.updateProgress(status: "Loading U-Boot...", fraction: 0.02)
                let uboot = try await self.payloads.uboot()
                runner.updateProgress(status: "Loading boot image...", fraction: 0.03)
                let bootImg = try await self.payloads.bootImg()
                runner.updateProgress(status: "Loading base modules...", fraction: 0.04)
                let baseHmods = try await self.payloads.baseHmods()
                let hakchiHmod = try await self.payloads.hakchiHmod()
                runner.updateProgress(status: "Payloads loaded, starting FEL...", fraction: 0.05)

                try await flashService.installHakchi(
                    fes1: fes1, uboot: uboot, bootImg: bootImg,
                    baseHmods: baseHmods, hakchiHmod: hakchiHmod,
                    backupSettings: backupSettings
                ) { status, progress in
                    runner.updateProgress(status: status, fraction: progress)
                }
            }

        case .uninstallHakchi:
            taskRunner.run(name: "Uninstalling custom kernel") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }
                let fes1 = try await self.payloads.fes1()
                let uboot = try await self.payloads.uboot()
                let bootImg = try await self.payloads.bootImg()

                try await flashService.uninstallHakchi(
                    fes1: fes1, uboot: uboot, bootImg: bootImg
                ) { status, progress in
                    runner.updateProgress(status: status, fraction: progress)
                }
            }

        case .factoryReset:
            let kernelImage = pendingKernelImage
            pendingKernelImage = nil

            taskRunner.run(name: "Factory reset") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }
                let fes1 = try await self.payloads.fes1()
                let uboot = try await self.payloads.uboot()
                let bootImg = try await self.payloads.bootImg()

                try await flashService.factoryReset(
                    fes1: fes1, uboot: uboot, bootImg: bootImg,
                    kernelImage: kernelImage
                ) { status, progress in
                    runner.updateProgress(status: status, fraction: progress)
                }
            }

        case .memboot:
            taskRunner.run(name: "Membooting custom kernel") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }
                let fes1 = try await self.payloads.fes1()
                let uboot = try await self.payloads.uboot()
                let bootImg = try await self.payloads.bootImg()

                runner.updateProgress(status: "Initializing FEL...", fraction: 0.1)
                try await self.deviceManager.felService.memboot(
                    fes1Data: fes1, ubootData: uboot, bootImgData: bootImg
                )
                runner.updateProgress(status: "Memboot complete", fraction: 1.0)
            }

        case .dumpStockKernel:
            taskRunner.run(name: "Dumping stock kernel") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }
                try await flashService.dumpStockKernel { status, progress in
                    runner.updateProgress(status: status, fraction: progress)
                }
            }

        default:
            deviceManager.suppressAutoConnect = false
            break
        }
    }

    func rebootConsole() async {
        guard !taskRunner.isRunning, !isPreparingSync else { return }
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        _ = try? await shell.execute("reboot")
    }

    func shutdownConsole() async {
        guard !taskRunner.isRunning, !isPreparingSync else { return }
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        _ = try? await shell.execute("poweroff")
    }

    // MARK: - Download from Console

    /// Download a game's ROM files from the console to a user-chosen directory.
    func downloadGameFromConsole(game: Game) {
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        let consoleType = deviceManager.consoleType
        let code = game.code

        // Determine remote path
        let remotePath: String
        if game.source == .stock {
            remotePath = "\(consoleType.originalGamesPath)/\(code)"
        } else {
            remotePath = "/var/lib/hakchi/games/\(consoleType.syncCode)/.storage/\(code)"
        }

        // Sanitize game name for use as filename
        let safeName = game.name
            .replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        // Show save panel — user picks destination folder
        let panel = NSOpenPanel()
        panel.title = "Save Game ROM"
        panel.message = "Choose where to save \(game.name)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"

        panel.begin { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard response == .OK, let destURL = panel.url else { return }

                self.showTaskProgress = true

                self.taskRunner.run(name: "Downloading \(game.name)") { runner in
                    runner.updateProgress(status: "Finding ROM on console...", fraction: 0.1)

                    // List remote files — find the ROM (skip .desktop, .png, .jpg, directories)
                    guard let listResult = try? await shell.execute("ls -1 \"\(remotePath)/\" 2>/dev/null"),
                          listResult.succeeded else {
                        throw DownloadError.notFound(code)
                    }

                    let files = listResult.output.components(separatedBy: .newlines)
                        .filter { !$0.isEmpty && !$0.hasPrefix(".") }

                    var romFile: String?
                    for filename in files {
                        if filename.hasSuffix(".png") || filename.hasSuffix(".jpg") { continue }
                        if filename.hasSuffix(".desktop") { continue }
                        let isDir = try? await shell.execute("[ -d \"\(remotePath)/\(filename)\" ] && echo yes")
                        if isDir?.output != "yes" {
                            romFile = filename
                            break
                        }
                    }

                    guard let romFilename = romFile else {
                        throw DownloadError.noFiles(code)
                    }

                    // Use game title with the ROM's file extension
                    let ext = (romFilename as NSString).pathExtension
                    let localName = ext.isEmpty ? safeName : "\(safeName).\(ext)"
                    let localFile = destURL.appendingPathComponent(localName)

                    runner.updateProgress(status: "Downloading \(localName)...", fraction: 0.2)

                    guard let result = try? await shell.execute(
                        "base64 \"\(remotePath)/\(romFilename)\" 2>/dev/null"
                    ), result.succeeded else {
                        throw DownloadError.noFiles(code)
                    }

                    let base64Str = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !base64Str.isEmpty,
                          let data = Data(base64Encoded: base64Str, options: .ignoreUnknownCharacters),
                          !data.isEmpty else {
                        throw DownloadError.noFiles(code)
                    }

                    try data.write(to: localFile)

                    runner.updateProgress(
                        status: "Saved \(localName)",
                        fraction: 1.0
                    )
                }
            }
        }
    }

    func chooseWorkspace() {
        guard !gameManager.isInspectingLegacy else {
            reportOperationError("Disconnect legacy inspection to edit the local library or change its workspace.")
            return
        }
        guard !taskRunner.isRunning, !isPreparingSync else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Use Workspace"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        AppConfig.shared.setWorkspace(folder)
        AppConfig.shared.save()
        gameManager.loadGames()
    }

    func copyEarlierMacLibrary() {
        guard !gameManager.isInspectingLegacy else {
            reportOperationError("Disconnect legacy inspection to edit the local library or change its workspace.")
            return
        }
        guard !taskRunner.isRunning, !isPreparingSync else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose the earlier app’s games folder. Its files will be copied and left intact."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try LibraryMigration.copy(from: source, to: AppConfig.shared.gamesDirectory)
            gameManager.loadGames()
        } catch { reportOperationError(error.localizedDescription) }
    }

    func reportOperationError(_ message: String) {
        operationError = message
        showOperationError = true
    }

    func syncGames() async {
        if deviceManager.legacyReport != nil || deviceManager.nativeSNESContext != nil { reviewLibrarySync(); return }
        guard !taskRunner.isRunning, !isPreparingSync, let shell = deviceManager.sshService else { return }
        guard gameManager.selectionError == nil else { reportOperationError(gameManager.selectionError!); return }
        let maximumGamesPerPage = AppConfig.shared.consoleMenuLimit.rawValue
        isPreparingSync = true
        defer { isPreparingSync = false }
        do {
            let inventory = try await DeviceInventoryService.inspect(shell: shell)
            guard inventory.profile.deviceID == deviceManager.uniqueId.filter({ !$0.isWhitespace }) else {
                throw SyncPlanError.invalidInput("Reconnect the console to refresh its library before syncing.")
            }
            guard inventory.canSync else { throw SyncPlanError.unsupportedConsole }
            let inputs = try SyncPlanAdapter.inputs(games: gameManager.games)
            let plan = try SyncPlanner.makePlan(inputs: inputs, installedCodes: inventory.installedCodes,
                profile: inventory.profile, freeBytes: inventory.freeBytes, reserveBytes: 10 * 1024 * 1024,
                maximumGamesPerPage: maximumGamesPerPage)
            preparedPlan = plan; preparedInventory = inventory
            showSyncConfirmation = true
        } catch { reportOperationError(error.localizedDescription) }
    }

    func confirmSync() {
        guard !taskRunner.isRunning, let plan = preparedPlan, let inventory = preparedInventory,
              let shell = deviceManager.sshService else { return }
        showSyncConfirmation = false
        preparedPlan = nil; preparedInventory = nil
        let workspace = AppConfig.shared.workspace
        let backups = workspace.backups
        let journals = workspace.journals
        let transactions = syncTransactions
        showTaskProgress = true
        taskRunner.run(name: "Backing up console") { [weak self] runner in
            let fresh = try await DeviceInventoryService.inspect(shell: shell)
            guard fresh.profile.deviceID == inventory.profile.deviceID, fresh.syncBase == inventory.syncBase,
                  fresh.installedCodes == inventory.installedCodes else {
                throw SyncPlanError.invalidInput("The console changed after the sync review. Review it again.")
            }
            try workspace.requireActiveBackupsAvailable()
            let backup = try await ConsoleBackupService.backup(inventory: fresh, shell: shell, destination: backups) { status, fraction in
                runner.updateProgress(status: status, fraction: fraction * 0.2)
            }
            let builder = GameSyncService(shell: shell, consoleType: inventory.consoleType)
            try await transactions.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: journals,
                prepare: { stage in
                    try await builder.prepareStage(plan: plan, stagingBase: stage, finalBase: inventory.syncBase!) { status, fraction in
                        runner.updateProgress(status: status, fraction: 0.2 + min(0.55, fraction * 0.55))
                    }
                }, progress: { status, fraction, cancellable in
                    await runner.report(status: status, fraction: 0.2 + fraction * 0.8, cancellable: cancellable)
                })
            guard let self else { return }
            await self.gameManager.refreshInstalledStatus(shell: shell, consoleType: inventory.consoleType)
        }
    }

    func exportConsoleBackup() {
        guard !taskRunner.isRunning, !gameManager.isLoading else { return }
        if let client = deviceManager.legacyClient, let report = deviceManager.legacyReport {
            let token = deviceManager.sessionID
            let workspace = AppConfig.shared.workspace
            let directory = workspace.backups
            showTaskProgress = true
            taskRunner.run(name: "Exporting legacy inspection backup") { [weak self] runner in
                do {
                    try workspace.requireActiveBackupsAvailable()
                    let backup = try await LegacyConsoleService.backup(client: client, report: report, destination: directory) { status, fraction in
                        runner.updateProgress(status: status, fraction: fraction)
                    }
                    await self?.legacyBackupFinished(backup, session: token)
                } catch {
                    await self?.legacyConnectionFailed(session: token)
                    throw error
                }
            }
            return
        }
        guard !taskRunner.isRunning, let shell = deviceManager.sshService else { return }
        let workspace = AppConfig.shared.workspace
        let directory = workspace.backups
        showTaskProgress = true
        taskRunner.run(name: "Exporting console backup") { runner in
            let inventory = try await DeviceInventoryService.inspect(shell: shell)
            try workspace.requireActiveBackupsAvailable()
            _ = try await ConsoleBackupService.backup(inventory: inventory, shell: shell, destination: directory) { status, fraction in
                runner.updateProgress(status: status, fraction: fraction)
            }
        }
    }

    private func legacyBackupFinished(_ directory: URL, session: UUID) {
        guard deviceManager.sessionID == session else { return }
        statusMessage = "Legacy backup verified: " + directory.lastPathComponent
    }

    private func legacyConnectionFailed(session: UUID) {
        guard deviceManager.sessionID == session else { return }
        deviceManager.manualDisconnect()
    }

    func recoverInterruptedSync() {
        guard !taskRunner.isRunning, let shell = deviceManager.sshService else { return }
        let profile = ConsoleProfile(deviceID: deviceManager.uniqueId, systemCode: deviceManager.consoleType.syncCode)
        let journals = AppConfig.shared.workspace.journals
        let transactions = syncTransactions
        showTaskProgress = true
        taskRunner.run(name: "Recovering interrupted sync", cancellable: false) { runner in
            try await transactions.recover(journalDirectory: journals, profile: profile, shell: shell)
            runner.updateProgress(status: "Recovery verified", fraction: 1)
        }
    }

    // MARK: - Import from Console

    /// Import custom games from the console into the local library
    func importFromConsole() async {
        guard !taskRunner.isRunning, deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        let consoleType = deviceManager.consoleType
        showTaskProgress = true

        taskRunner.run(name: "Importing games from console") { [weak self] runner in
            guard let self else { return }
            let count = try await self.gameManager.importGamesFromConsole(
                shell: shell,
                consoleType: consoleType
            ) { status, progress in
                runner.updateProgress(status: status, fraction: progress)
            }
            runner.updateProgress(
                status: count > 0 ? "Imported \(count) game(s)" : "No new games to import",
                fraction: 1.0
            )
        }
    }

    // MARK: - Game navigation

    func selectNextGame() {
        let games = filteredGames.filter { !$0.isStock }
        guard !games.isEmpty else { return }
        if let current = selectedGame, let idx = games.firstIndex(of: current) {
            let next = games.index(after: idx)
            selectedGame = next < games.endIndex ? games[next] : games[games.startIndex]
        } else {
            selectedGame = games.first
        }
    }

    func selectPreviousGame() {
        let games = filteredGames.filter { !$0.isStock }
        guard !games.isEmpty else { return }
        if let current = selectedGame, let idx = games.firstIndex(of: current) {
            if idx > games.startIndex {
                selectedGame = games[games.index(before: idx)]
            } else {
                selectedGame = games.last
            }
        } else {
            selectedGame = games.last
        }
    }

    // MARK: - Game actions

    func deleteSelectedGame() {
        guard let game = selectedGame, game.source == .local else { return }
        showDeleteConfirmation = true
    }

    func confirmDeleteSelectedGame() {
        guard let game = selectedGame else { return }
        gameManager.deleteGame(game)
        selectedGame = nil
        showDeleteConfirmation = false
    }

    var canChangeGameSelection: Bool {
        !gameManager.isInspectingLegacy && !gameManager.isLoading && gameManager.selectionError == nil
            && !taskRunner.isRunning && !isPreparingSync
    }

    func setGamesSelectedForSync(_ selected: Bool, codes: Set<String>) {
        guard canChangeGameSelection else { return }
        gameManager.setSelection(selected, codes: codes)
    }

    func setAllCustomGamesSelectedForSync(_ selected: Bool) {
        setGamesSelectedForSync(selected, codes: Set(gameManager.games.filter { !$0.isStock }.map(\.code)))
    }

    // MARK: - ROM import

    func replaceROMFolder() {
        guard !taskRunner.isRunning, !isPreparingSync, !gameManager.isLoading else { return }
        let console = AppConfig.shared.lastConsoleType
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = "Replace Imported Library"; panel.prompt = "Use This Folder"
        panel.message = "Choose a folder for your new local library. Matching games keep your edits.\nThe previous library is saved on this Mac. Console games change only when you sync."
        ROMImportPanel.present(panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let folder = panel.url else { return }
            do {
                let urls = try ROMImportPolicy.collectFolder(folder, for: console)
                _ = try replaceImportedLibrary(urls: urls, console: console, reviewIncluded: reviewIncludedImports)
                selectedGame = nil; searchText = ""
                statusMessage = "New library: \(gameManager.games.filter { $0.source == .local }.count) games. Matching edits kept; previous imports saved in Removed Libraries. Connect and choose Sync Library when ready."
            } catch is CancellationError { statusMessage = "Import canceled. Your library is unchanged." }
            catch { reportOperationError(error.localizedDescription) }
        }
    }

    @discardableResult
    func replaceImportedLibrary(urls: [URL], console: ConsoleType,
                                reviewIncluded: ([IncludedGameDuplicate]) -> IncludedGameImportChoice) throws -> URL {
        guard !taskRunner.isRunning, !isPreparingSync, !gameManager.isLoading else { throw LegacyInspectionError.busy }
        let archived = try gameManager.replaceLocalLibrary(urls: urls, consoleType: console, preservingEdits: true, reviewIncluded: reviewIncluded)
        deviceManager.manualDisconnect(); gameManager.clearConsoleGames()
        return archived
    }

    func addROMFolder() {
        guard !gameManager.isInspectingLegacy, !taskRunner.isRunning else { return }
        let console = deviceManager.consoleType == .unknown ? AppConfig.shared.lastConsoleType : deviceManager.consoleType
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = "Add ROM Folder"; panel.prompt = "Add ROM Folder"
        panel.message = "Copy supported ROMs and ZIP/7z contents from this folder.\nSubfolders are not scanned. Your original files stay unchanged."
        ROMImportPanel.present(panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let folder = panel.url else { return }
            startGameFileImport(console: console, folder: folder)
        }
    }

    func addROMs() {
        guard !gameManager.isInspectingLegacy else {
            reportOperationError("Disconnect legacy inspection to edit the local library or change its workspace.")
            return
        }
        guard !taskRunner.isRunning, !isPreparingSync, !gameManager.isLoading else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let console = deviceManager.consoleType == .unknown ? AppConfig.shared.lastConsoleType : deviceManager.consoleType
        let extensions = ROMImportPolicy.extensions(for: console)
        guard !extensions.isEmpty else {
            reportOperationError("Choose a console library before adding game files.")
            return
        }
        panel.title = "Add Game Files — " + console.displayName
        panel.message = ROMImportPolicy.pickerMessage(for: console)
        panel.allowedContentTypes = (extensions + ROMImportPolicy.archiveExtensions.sorted())
            .compactMap { UTType(filenameExtension: $0) }
        ROMImportPanel.present(panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK else { return }
            startGameFileImport(console: console, urls: panel.urls)
        }
    }

    func startGameFileImport(console: ConsoleType, urls: [URL] = [], folder: URL? = nil) {
        guard !taskRunner.isRunning, !isPreparingSync, !gameManager.isLoading, !gameManager.isInspectingLegacy else { return }
        showTaskProgress = true
        taskRunner.run(name: "Adding Game Files", cancellable: false) { [weak self] reporter in
            guard let self else { throw CancellationError() }
            let selected: [URL]
            if let folder {
                await reporter.report(status: "Finding game files…")
                selected = try await Task.detached(priority: .userInitiated) { try ROMImportPolicy.collectFolder(folder, for: console) }.value
            } else { selected = urls }
            let result = try await self.gameManager.importROMsResponsive(urls: selected, consoleType: console,
                reviewIncluded: { [weak self] matches in self?.reviewIncludedImports(matches) ?? .cancel },
                progress: { status, fraction in await reporter.report(status: status, fraction: fraction) })
            await MainActor.run { self.statusMessage = result.message }
            await reporter.report(status: result.message, fraction: 1)
        }
    }

    private func reviewIncludedImports(_ matches: [IncludedGameDuplicate]) -> IncludedGameImportChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = matches.count == 1 ? "This game may already be included" : "\(matches.count) games may already be included"
        let titles = matches.prefix(8).map { "• " + $0.importedTitle }.joined(separator: "\n")
        let more = matches.count > 8 ? "\n…and \(matches.count - 8) more." : ""
        alert.informativeText = "These names match games included with this console:\n\n" + titles + more +
            "\n\nSkip Matches keeps the built-in versions. Keep Copies adds your files to the Mac library, unchecked for syncing. You can select them later if you want a different version. A matching name does not guarantee the files are identical."
        alert.addButton(withTitle: "Skip Matches")
        alert.addButton(withTitle: "Keep Copies")
        alert.addButton(withTitle: "Cancel Import")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .skipMatches
        case .alertSecondButtonReturn: return .keepCopies
        default: return .cancel
        }
    }

    // MARK: - Filtered games

    var filteredGames: [Game] {
        if searchText.isEmpty {
            return AppConfig.shared.libraryOrder.ordered(gameManager.games)
        }
        return AppConfig.shared.libraryOrder.ordered(gameManager.games.filter { game in
            game.name.localizedCaseInsensitiveContains(searchText)
        })
    }
}
