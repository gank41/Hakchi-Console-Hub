import Foundation
import SwiftHakchiCore

/// Owns exactly one recovery SSH connection. No external shell or reconnect is exposed.
actor NativeStockRestoreIO: StockRestoreIO {
    private let shell: SSHService
    private let recovery: NativeRecoveryProbeIO
    private var partitionSHA256: String?
    init() {
        let shell = SSHService(); self.shell = shell
        recovery = NativeRecoveryProbeIO(shell: shell)
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await recovery.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await recovery.boot(inputs,expected:expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await recovery.connect(expected:expected) }
    func observe() async throws -> String { try await recovery.observe() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await recovery.readBoot2(slot) }
    func disconnect() async { partitionSHA256 = nil; await recovery.disconnect() }
    func verifyPartitions() async throws {
        try Task.checkCancellation()
        let result = try await shell.execute(StockRestoreCommands.partitions, timeout:15000)
        // Capture bounded diagnostic evidence even when the query fails. It remains
        // in the private host transcript before the refusal discards remote RAM files.
        print("Partition query exit status: \(result.exitCode)")
        print("Raw legacy partition evidence:\n" + String(decoding:result.stdoutData.prefix(16384),as:UTF8.self))
        if !result.stderr.isEmpty { print("Partition query stderr:\n" + String(decoding:result.stderr.utf8.prefix(16384),as:UTF8.self)) }
        let bytes = try StockRestoreCompletion.partitionData(result)
        partitionSHA256 = BackupManifest.digest(bytes)
    }
    func stage(stock: Data, id: UUID) async throws {
        _ = try StockKernelEvidence(data:stock)
        guard partitionSHA256 != nil else { throw RecoveryProbeError.refused("Partition preflight is missing.") }
        try Task.checkCancellation()
        let created = try await shell.execute(StockRestoreCommands.create(id:id))
        try StockRestoreCompletion.require(created,marker:StockRestoreCompletion.created(id:id))
        try Task.checkCancellation()
        try await shell.upload(data:stock,to:StockRestoreCommands.directory + "/stock.img")
        try Task.checkCancellation()
        let check = try await shell.execute(StockRestoreCommands.checkedStage(id:id,sha:BackupManifest.digest(stock),count:stock.count))
        try StockRestoreCompletion.require(check,marker:StockRestoreCompletion.staged(id:id,sha:BackupManifest.digest(stock)))
    }
    func burn(id: UUID, expectedSHA256: String, expectedBytes: Int) async throws {
        guard let partitionSHA256 else { throw RecoveryProbeError.refused("Partition preflight is missing.") }
        try Task.checkCancellation()
        let result = try await shell.execute(StockRestoreCommands.burn(id:id,sha:expectedSHA256,count:expectedBytes,partitionSHA256:partitionSHA256), timeout:120000)
        guard result.succeeded, result.stdoutData == Data(StockRestoreCommands.marker(id:id,sha:expectedSHA256).utf8) else {
            throw RecoveryProbeError.refused("Stock boot2 command completion was not verified. Preserve power, cables and journal; do not retry or reboot.")
        }
    }
}
