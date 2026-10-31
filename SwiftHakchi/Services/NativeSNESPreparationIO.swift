import Foundation

struct BoundedSSHExecution: Sendable {
    let stdout: Data, stderr: Data
    let exitCode: Int, transportCode: Int
}
enum SNESStartupReceipt {
    static func capture(using execute: () async throws -> BoundedSSHExecution) async throws -> Data {
        let response: BoundedSSHExecution
        do { response = try await execute() }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw SNESStartupTransportFailure(frame: Data(), stageLog: Data("Capture connection stopped before a response was received.\n".utf8))
        }
        guard response.transportCode == 0, response.exitCode == 0,
              response.stdout.count <= SNESStartupFrame.maximumSize, response.stderr.count <= 16384 else {
            throw SNESStartupTransportFailure(frame: Data(response.stdout.prefix(SNESStartupFrame.maximumSize)), stageLog: Data(response.stderr.prefix(16384)))
        }
        return response.stdout
    }
}

actor NativeSNESPreparationIO: SNESPreparationIO {
    private let shell: SSHService
    private let recovery: NativeRecoveryProbeIO
    private let source: SNESPreparationSource
    private var partitionsChecked = false, stockChecked = false
    init(source: SNESPreparationSource) {
        self.source = source
        let shell = SSHService(); self.shell = shell
        recovery = NativeRecoveryProbeIO(shell: shell, observationCommand: SNESBackupPolicy.command)
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await recovery.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await recovery.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await recovery.connect(expected: expected) }
    func observe() async throws -> String { try await recovery.observe() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await recovery.readBoot2(slot) }
    func readBoot1() async throws -> Data { try await recovery.readBoot1() }
    func readDataSuperblock() async throws -> Data { try await recovery.readDataSuperblock() }
    func readPartitions() async throws -> Data {
        partitionsChecked = false
        let bytes = try await recovery.readPartitions()
        guard bytes == source.partitions else { throw SNESOfflineSource.failure() }
        partitionsChecked = true; return bytes
    }
    func stageStock(_ data: Data, id: UUID) async throws {
        stockChecked = false; try Task.checkCancellation(); try source.revalidate()
        guard partitionsChecked, data == source.stock else { throw SNESOfflineSource.failure() }
        try source.requireObservation(SNESBackupPolicy.observation(await recovery.observe()))
        let created = try await shell.execute(SNESPreparationCommands.create(id: id))
        try StockRestoreCompletion.require(created, marker: SNESPreparationCommands.created(id: id))
        try Task.checkCancellation()
        try await shell.upload(data: data, to: SNESPreparationCommands.directory + "/stock.img")
        try Task.checkCancellation(); try source.revalidate()
        let checked = try await shell.execute(SNESPreparationCommands.checkedStage(id: id), timeout: 30000)
        try StockRestoreCompletion.require(checked, marker: SNESPreparationCommands.staged(id: id))
        stockChecked = true
    }
    func readStartup() async throws -> Data {
        try Task.checkCancellation(); guard stockChecked else { throw SNESOfflineSource.failure() }
        let bytes = try await SNESStartupReceipt.capture {
            try await shell.executeBounded(SNESStartupCommand.read, stdoutLimit: SNESStartupFrame.maximumSize, stderrLimit: 16384, timeout: 120000)
        }
        try Task.checkCancellation()
        return bytes
    }
    func disconnect() async {
        partitionsChecked = false; stockChecked = false; await recovery.disconnect()
    }
}
