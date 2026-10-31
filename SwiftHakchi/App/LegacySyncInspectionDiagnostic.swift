import Foundation

/// An independent, read-only view of an interrupted legacy menu switch.
@MainActor enum LegacySyncInspectionDiagnostic {
    static func run(operationID: UUID) async throws -> String {
        try RecoveryFirmwareJournalPolicy.requireOwner()
        let store = LegacySyncJournalStore(directory: AppConfig.shared.workspace.journals)
        let journal = try await store.load(operationID)
        try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
        let client = LegacyInspectionClient()
        try await client.connect(timeoutMilliseconds: 3000)
        do {
            let lease = try await client.reserveForChange()
            do {
                try LegacyDeviceIdentity.requireFirstNES(try await LegacyDeviceIdentity.read(client: lease))
                let result = try await lease.perform(.inspectStage(operationID, journal.treeSHA256))
                guard result.succeeded, result.stderr.isEmpty else {
                    throw LegacyInspectionError.invalidResponse
                }
                let state = try LegacySyncCommands.parseInspection(result.stdoutData,
                    operationID: operationID)
                let console = try await LegacyConsoleService.inspect(client: lease)
                await lease.release()
                await client.disconnect()
                let fields: [String: Any] = [
                    "mode": "inspect-legacy-transaction", "USBOpened": true,
                    "gamesChanged": false, "operationID": operationID.uuidString,
                    "hostPhase": journal.phase.rawValue, "consolePhase": state.phase.rawValue,
                    "activePage": console.activePage,
                    "bootVersion": console.bootVersion,
                    "kernelVersion": console.kernelVersion,
                    "scriptVersion": console.scriptVersion,
                    "savesPath": console.savesPath,
                    "stockCodeCount": console.stockCodes.count,
                    "visibleCodeCount": console.visibleCodes.count,
                    "freeBytes": console.freeBytes,
                    "outcome": String(describing: state.outcome),
                    "transaction": state.transaction, "live": state.live,
                    "old": state.old, "stage": state.stage, "archive": state.archive,
                    "verified": state.verified, "failed": state.failed, "lock": state.lock
                ]
                return String(decoding: try JSONSerialization.data(withJSONObject: fields,
                    options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
            } catch { await lease.release(); throw error }
        } catch { await client.disconnect(); throw error }
    }
}
