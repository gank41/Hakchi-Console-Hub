import Foundation
import Combine
import os

/// Owns one normal-mode connection. Shared recovery USB IDs never establish a console model.
@MainActor
final class DeviceManager: ObservableObject {
    @Published var isConnected = false
    @Published var felDevicePresent = false
    @Published var consoleType: ConsoleType = .unknown
    @Published var customFirmwareLoaded = false
    @Published var canSync = false
    @Published var canInteract = false
    @Published var bootVersion = ""
    @Published var kernelVersion = ""
    @Published var scriptVersion = ""
    @Published var uniqueId = ""
    let usbMonitor = USBMonitor()
    let felService = FELService()
    private(set) var sshService: SSHService?
    private(set) var legacyClient: LegacyInspectionClient?
    @Published private(set) var nativeSNESContext: SNESLibraryContext?
    private(set) var nativeSNES: SNESLibraryConnectionSession?
    @Published private(set) var legacyReport: LegacyConsoleReport?
    @Published private(set) var lastConnectionError: String?
    @Published private(set) var connectionStage: ConsoleConnectionStage?
    var isConnecting: Bool { connectionStage != nil }
    @discardableResult func updateConnectionStage(_ stage: ConsoleConnectionStage, session: UUID) -> Bool {
        guard session == sessionID else { return false }
        connectionStage = stage
        return true
    }
    private func recordConnectionStage(_ stage: ConsoleConnectionStage, session: UUID, started: ContinuousClock.Instant) {
        guard updateConnectionStage(stage, session: session) else { return }
        Self.debugLog("Connection stage=" + stage.rawValue + " elapsed=" + String(describing: started.duration(to: .now)))
    }
    private(set) var sessionID = UUID()
    private let makeLegacyClient: @Sendable () -> LegacyInspectionClient
    private let connectRuntime: (@Sendable (RecoveryProbeUSBDevice) async throws -> ConnectedConsoleInfo)?
    private var cancellables = Set<AnyCancellable>()
    private var connectTask: Task<Void, Never>?
    private var manualConnectRequest: UUID?
    private var manualConnectAttempt: (id: UUID, task: Task<Void, Never>)?
    private var closingTask: Task<Void, Never>?
    private var observedDevices: [RecoveryProbeUSBDevice] = []
    private var connectedAttachmentID: UInt64?
    private var attemptedAttachmentID: UInt64?
    private var manuallyDisconnectedID: UInt64?
    private var observedRNDISPresent = false
    private var awaitRecoveryUnplug = false

    /// A recovery operation owns USB until it explicitly releases it or normal boot is restored.
    var suppressAutoConnect = false {
        didSet {
            if suppressAutoConnect {
                connectTask?.cancel()
                manualConnectRequest = nil
                manualConnectAttempt?.task.cancel()
            }
        }
    }

    init(makeLegacyClient: @escaping @Sendable () -> LegacyInspectionClient = {
        LegacyInspectionClient(diagnosticsURL: AppConfig.shared.workspace.logs.appendingPathComponent("legacy-usb-failures.jsonl"))
    }, connectRuntime: (@Sendable (RecoveryProbeUSBDevice) async throws -> ConnectedConsoleInfo)? = nil) {
        self.makeLegacyClient = makeLegacyClient; self.connectRuntime = connectRuntime
    }
    static func debugLog(_ message: String) {
        let directory = AppConfig.shared.workspace.logs
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("device.log")
        let data = Data(("[" + ISO8601DateFormatter().string(from: Date()) + "] " + message + "\n").utf8)
        if let file = try? FileHandle(forWritingTo: path) {
            _ = try? file.seekToEnd(); try? file.write(contentsOf: data); try? file.close()
        } else { try? data.write(to: path, options: .atomic) }
    }
    func start() {
        usbMonitor.$attachments.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] devices in self?.enqueue(devices) }.store(in: &cancellables)
        usbMonitor.start()
    }
    func stop() {
        usbMonitor.stop(); cancellables.removeAll(); connectTask?.cancel()
        manualConnectRequest = nil; manualConnectAttempt?.task.cancel(); _ = disconnect()
    }
    private func enqueue(_ devices: [RecoveryProbeUSBDevice]) {
        let prior = connectTask
        prior?.cancel()
        // Invalidate now, before waiting for a cancelled native open to finish.
        if ConsoleAttachmentPolicy.single(devices)?.registryEntryID != connectedAttachmentID {
            _ = disconnect()
        }
        connectTask = Task { @MainActor [weak self] in
            await prior?.value
            guard let self, !Task.isCancelled else { return }
            await self.inspectAttachments(devices)
        }
    }
    func inspectAttachments(_ devices: [RecoveryProbeUSBDevice]) async {
        let changed = devices != observedDevices
        observedDevices = devices
        felDevicePresent = devices.contains { ConsoleAttachmentPolicy.kind(of: $0) == .recovery }
        if awaitRecoveryUnplug, devices.isEmpty {
            awaitRecoveryUnplug = false; suppressAutoConnect = false
        }
        guard let attachment = ConsoleAttachmentPolicy.single(devices) else {
            _ = disconnect()
            if changed { attemptedAttachmentID = nil }
            if devices.count > 1 { lastConnectionError = "Connect one console at a time." }
            return
        }
        let id = attachment.registryEntryID!
        if connectedAttachmentID != id {
            _ = disconnect()
            attemptedAttachmentID = nil
        }
        guard !suppressAutoConnect, manuallyDisconnectedID != id,
              !isConnected, attemptedAttachmentID != id else { return }
        guard [.legacy, .nativeSNES, .rndis].contains(ConsoleAttachmentPolicy.kind(of: attachment)) else { return }
        attemptedAttachmentID = id
        await connect(attachment)
    }
    private func connect(_ attachment: RecoveryProbeUSBDevice) async {
        let previousClose = disconnect()
        let token = sessionID
        connectedAttachmentID = attachment.registryEntryID
        lastConnectionError = nil
        let started = ContinuousClock.now
        recordConnectionStage(.closingPrevious, session: token, started: started)
        await previousClose?.value
        guard token == sessionID, !Task.isCancelled else {
            if token == sessionID { connectionStage = nil }
            return
        }
        do {
            let result: ConnectedConsoleInfo
            if let connectRuntime { result = try await connectRuntime(attachment) }
            else {
                result = try await ConsoleRuntimeConnection.connect(attachment, makeLegacyClient: makeLegacyClient,
                    workspace: AppConfig.shared.workspace, sessionID: token, progress: { [weak self] stage in
                        await self?.recordConnectionStage(stage, session: token, started: started)
                    })
            }
            guard sessionID == token, !Task.isCancelled, !suppressAutoConnect,
                  observedDevices.contains(attachment) else {
                if sessionID == token { connectionStage = nil }
                await result.close(); return
            }
            sshService = result.shell; legacyClient = result.legacy; legacyReport = result.legacyReport
            nativeSNES = result.nativeSNES; nativeSNESContext = result.nativeSNESContext
            consoleType = result.consoleType; uniqueId = result.uniqueID
            bootVersion = result.bootVersion; kernelVersion = result.kernelVersion; scriptVersion = result.scriptVersion
            customFirmwareLoaded = result.customFirmwareLoaded
            canInteract = result.canInteract && result.consoleType == .nes
            canSync = result.canSync && result.consoleType == .nes
            isConnected = true
            connectionStage = nil
            Self.debugLog("Connected verified runtime type=" + result.consoleType.rawValue)
        } catch {
            guard token == sessionID else { return }
            connectionStage = nil
            guard !Task.isCancelled else { return }
            lastConnectionError = error.localizedDescription
            Self.debugLog("Runtime connection refused: " + error.localizedDescription)
        }
    }
    func manualDisconnect() {
        lastConnectionError = nil
        manuallyDisconnectedID = ConsoleAttachmentPolicy.single(observedDevices)?.registryEntryID
            ?? ConsoleAttachmentPolicy.single(usbMonitor.attachments)?.registryEntryID
        manualConnectRequest = nil; manualConnectAttempt?.task.cancel()
        connectTask?.cancel(); _ = disconnect()
    }
    @discardableResult func reconnect() async -> Bool {
        guard !suppressAutoConnect else {
            lastConnectionError = "Another console operation is using USB. Finish it before connecting."; return false
        }
        let request = UUID()
        manualConnectRequest = request
        let prior = connectTask, priorManual = manualConnectAttempt
        prior?.cancel(); priorManual?.task.cancel()
        await prior?.value; await priorManual?.task.value
        if manualConnectAttempt?.id == priorManual?.id { manualConnectAttempt = nil }
        guard !Task.isCancelled, !suppressAutoConnect, manualConnectRequest == request else { return false }
        manuallyDisconnectedID = nil; attemptedAttachmentID = nil
        observedDevices = usbMonitor.attachments
        guard let attachment = ConsoleAttachmentPolicy.single(observedDevices) else {
            lastConnectionError = observedDevices.count > 1 ? "Connect one console at a time."
                : "No console management connection was found. A stock console may need initial setup before normal-mode game management is available."
            return false
        }
        guard ConsoleAttachmentPolicy.kind(of: attachment) != .recovery else {
            lastConnectionError = "Recovery mode is ready. It cannot show a game library yet. Use the console backup or setup action, or boot normally if the console is already modified."
            return false
        }
        let attempt = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.connect(attachment)
        }
        manualConnectAttempt = (request, attempt)
        await withTaskCancellationHandler(operation: { await attempt.value }, onCancel: { attempt.cancel() })
        if manualConnectAttempt?.id == request { manualConnectAttempt = nil }
        guard !Task.isCancelled, !suppressAutoConnect, manualConnectRequest == request else { return false }
        return isConnected
    }
    /// Compatibility entry point for existing presence observers; absent startup notifications are harmless.
    func handleRNDISPresence(_ present: Bool) {
        let previous = observedRNDISPresent; observedRNDISPresent = present
        if previous != present { enqueue(usbMonitor.attachments) }
    }
    func pauseForRecovery() async {
        suppressAutoConnect = true
        let prior = connectTask, manual = manualConnectAttempt
        manualConnectRequest = nil
        prior?.cancel(); manual?.task.cancel()
        let close = disconnect()
        await prior?.value; await manual?.task.value; await close?.value
        if manualConnectAttempt?.id == manual?.id { manualConnectAttempt = nil }
    }
    /// Resume the normal tracked connection task after a foreground USB workflow releases its handle.
    func resumeAfterExclusive() {
        suppressAutoConnect = false; manuallyDisconnectedID = nil; attemptedAttachmentID = nil
        enqueue(usbMonitor.attachments)
    }
    func waitForNormalBootAfterRecovery() {
        awaitRecoveryUnplug = true
        // Never auto-adopt the temporary RNDIS recovery shell as installed firmware.
        suppressAutoConnect = true
    }
    func refreshLegacyReport() async throws {
        let token = sessionID
        guard consoleType == .nes, let client = legacyClient, legacyReport != nil else { throw LegacyInspectionError.disconnected }
        let report = try await LegacyConsoleService.inspect(client: client)
        guard sessionID == token else { throw LegacyInspectionError.disconnected }
        legacyReport = report
    }
    @discardableResult private func disconnect() -> Task<Void, Never>? {
        let shell = sshService, legacy = legacyClient, native = nativeSNES, previous = closingTask
        sessionID = UUID(); connectedAttachmentID = nil
        connectionStage = nil
        sshService = nil; legacyClient = nil; legacyReport = nil; nativeSNES = nil; nativeSNESContext = nil
        isConnected = false; canSync = false; canInteract = false
        customFirmwareLoaded = false; consoleType = .unknown
        bootVersion = ""; kernelVersion = ""; scriptVersion = ""; uniqueId = ""
        guard shell != nil || legacy != nil || native != nil else { return previous }
        let close = Task { await previous?.value; await shell?.disconnect(); await legacy?.disconnect(); await native?.disconnect() }
        closingTask = close
        return close
    }
}

// MARK: - Version Parsing

struct VersionTuple: Comparable {
    let components: [Int]

    init(_ values: Int...) {
        components = values
    }

    static func parse(_ string: String) -> VersionTuple {
        let pattern = #"(?:\d+[\.-]){2,}(?:\d+)+"#
        guard let range = string.range(of: pattern, options: .regularExpression) else {
            return VersionTuple(0, 0, 0, 0)
        }
        let versionStr = String(string[range])
        let parts = versionStr
            .replacingOccurrences(of: "-", with: ".")
            .components(separatedBy: ".")
            .compactMap { Int($0) }
        return VersionTuple(parts: parts)
    }

    private init(parts: [Int]) {
        components = parts
    }

    static func < (lhs: VersionTuple, rhs: VersionTuple) -> Bool {
        let maxLen = max(lhs.components.count, rhs.components.count)
        for i in 0..<maxLen {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: VersionTuple, rhs: VersionTuple) -> Bool {
        let maxLen = max(lhs.components.count, rhs.components.count)
        for i in 0..<maxLen {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return false }
        }
        return true
    }
}
