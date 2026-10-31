import Foundation
import SwiftHakchiCore

/// Owns one recovery SSH connection for a legacy activation transaction.
actor NativeLegacyBoot2ActivationIO: LegacyBoot2ActivationIO {
    private let shell: SSHService
    private let recovery: NativeRecoveryProbeIO
    private var partitionSHA256: String?

    init() {
        let shell = SSHService()
        self.shell = shell
        recovery = NativeRecoveryProbeIO(shell: shell)
    }

    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await recovery.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await recovery.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await recovery.connect(expected: expected) }
    func observe() async throws -> String { try await recovery.observe() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await recovery.readBoot2(slot) }
    func disconnect() async { partitionSHA256 = nil; await recovery.disconnect() }

    func verifyPartitions() async throws {
        try Task.checkCancellation()
        let result = try await shell.execute(LegacyBoot2ActivationCommands.partitions, timeout: 15_000)
        let bytes = try StockRestoreCompletion.partitionData(result)
        partitionSHA256 = BackupManifest.digest(bytes)
    }

    func stage(legacy: Data, id: UUID) async throws {
        guard legacy.count == LegacyBoot2ActivationPlan.legacyBytes,
              BackupManifest.digest(legacy) == LegacyBoot2ActivationPlan.legacySHA256,
              partitionSHA256 != nil else {
            throw RecoveryProbeError.refused("The pinned legacy image or partition preflight is missing.")
        }
        try Task.checkCancellation()
        let created = try await shell.execute(LegacyBoot2ActivationCommands.create(id: id))
        try StockRestoreCompletion.require(created, marker: LegacyBoot2ActivationCommands.created(id: id))
        try Task.checkCancellation()
        try await shell.upload(data: legacy, to: LegacyBoot2ActivationCommands.directory + "/legacy.img")
        try Task.checkCancellation()
        let checked = try await shell.execute(LegacyBoot2ActivationCommands.checkedStage(
            id: id, sha: LegacyBoot2ActivationPlan.legacySHA256, count: legacy.count))
        try StockRestoreCompletion.require(checked, marker: LegacyBoot2ActivationCommands.staged(
            id: id, sha: LegacyBoot2ActivationPlan.legacySHA256))
    }

    func burn(id: UUID, expectedSHA256: String, expectedBytes: Int) async throws {
        guard let partitionSHA256,
              expectedSHA256 == LegacyBoot2ActivationPlan.legacySHA256,
              expectedBytes == LegacyBoot2ActivationPlan.legacyBytes else {
            throw RecoveryProbeError.refused("Pinned legacy image or partition evidence changed before write.")
        }
        try Task.checkCancellation()
        let result = try await shell.execute(LegacyBoot2ActivationCommands.burn(
            id: id, sha: expectedSHA256, count: expectedBytes, partitionSHA256: partitionSHA256), timeout: 120_000)
        guard result.succeeded,
              result.stdoutData == Data(LegacyBoot2ActivationCommands.marker(id: id, sha: expectedSHA256).utf8) else {
            throw RecoveryProbeError.refused("Legacy boot2 write completion was not verified. Preserve power, cables and journal; do not retry or reboot.")
        }
    }
}
