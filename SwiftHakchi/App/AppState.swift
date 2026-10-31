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
         checkRecoveryHost: @escaping @Sendable () async throws -> Void = { try await RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() }) {
        self.deviceManager = deviceManager ?? DeviceManager()
        self.gameManager = gameManager ?? GameManagerService(config: config)
        self.connectionConfig = config
        self.saveConnectionConfiguration = saveConfiguration ?? { config.save() }
        self.checkRecoveryHost = checkRecoveryHost

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
        if AppConfig.shared.lastConsoleType != console {
            AppConfig.shared.lastDeviceId = ""
            AppConfig.shared.installedGameCodes = []
        }
        AppConfig.shared.lastConsoleType = console
        AppConfig.shared.save()
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

    func captureSNESKernel(progress: @escaping RecoveryProgressSink) async throws -> URL {
        try await captureSNES(progress: progress, includeSetupEvidence: false)
    }

    func captureSNESSetup(progress: @escaping RecoveryProgressSink) async throws -> URL {
        try await captureSNES(progress: progress, includeSetupEvidence: true)
    }

    private func captureSNES(progress: @escaping RecoveryProgressSink, includeSetupEvidence: Bool) async throws -> URL {
        guard isPreparingSync, connectionConfig.lastConsoleType == .snesUsa,
              !taskRunner.isRunning else { throw RecoveryProbeError.refused("Select the US SNES library and open Prepare SNES Setup first.") }
        try await checkRecoveryHost()
        await deviceManager.pauseForRecovery()
        defer { deviceManager.waitForNormalBootAfterRecovery() }
        await progress(.checkingMaterial)
        let root = connectionConfig.workspace.backups
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try RecoveryBootSnapshotStore(root: root)
        let inputs = try await payloads.pinnedRecoveryInputs()
        let io = NativeRecoveryProbeIO(observationCommand: SNESBackupPolicy.command)
        let saved: URL
        if includeSetupEvidence {
            do {
                let report = try await SNESSetupReadinessService().capture(inputs: inputs, io: io, progress: progress)
                saved = try await store.saveSNESSetup(report)
            } catch let failure as SNESSetupDiagnosticFailure {
                let directory = try await store.saveSNESSetupDiagnostic(failure)
                throw SNESSetupDiagnosticSavedError(directory: directory)
            }
        } else {
            let report = try await SNESKernelBackupService().capture(inputs: inputs, io: io, progress: progress)
            saved = try await store.saveSNES(report)
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
            do {
                let urls = try ROMImportPolicy.collectFolder(folder, for: console)
                let result = try gameManager.importROMs(urls: urls, consoleType: console, reviewIncluded: reviewIncludedImports)
                statusMessage = result.message
            } catch is CancellationError { statusMessage = "Import canceled. Your library is unchanged." }
            catch { reportOperationError(error.localizedDescription) }
        }
    }

    func addROMs() {
        guard !gameManager.isInspectingLegacy else {
            reportOperationError("Disconnect legacy inspection to edit the local library or change its workspace.")
            return
        }
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
            do {
                let result = try gameManager.importROMs(urls: panel.urls, consoleType: console, reviewIncluded: reviewIncludedImports)
                statusMessage = result.message
            } catch is CancellationError { statusMessage = "Import canceled. Your library is unchanged." }
            catch { statusMessage = error.localizedDescription }
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
