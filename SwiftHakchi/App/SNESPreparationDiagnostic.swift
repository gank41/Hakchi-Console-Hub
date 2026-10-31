import Foundation

struct SNESPreparationDiagnosticSavedError: Error, LocalizedError {
    let directory: URL
    var errorDescription: String? { "The startup check stopped without installing anything. Private diagnostic files were saved at \(directory.path). Return the console to normal boot when instructed." }
}

enum SNESPreparationDiagnostic {
    static func runIfPresent(_ args: [String],
        loadInputs: @Sendable () async throws -> RecoveryBootInputs = { try await PayloadService.shared.pinnedRecoveryInputs() },
        checkHost: @Sendable () async throws -> Void = { try await RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makeIO: @Sendable (SNESPreparationSource) -> any SNESPreparationIO = { NativeSNESPreparationIO(source: $0) },
        progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String? {
        guard args.first == "--prepare-snes-recovery" else { return nil }
        guard args.count == 3, args.dropFirst().allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
            throw RecoveryProbeError.refused("Usage: --prepare-snes-recovery /completed/SNES/setup /existing/Backups. This check does not install firmware.")
        }
        try Task.checkCancellation(); await progress(.checkingMaterial)
        let source = try SNESPreparationSource.load(SNESOfflineSource.load(snapshot: URL(fileURLWithPath: args[1])))
        let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: args[2]))
        let inputs = try await loadInputs(); _ = try inputs.prepare()
        try source.revalidate(); try await checkHost(); try Task.checkCancellation(); try source.revalidate()
        let directory: URL
        do {
            let result = try await SNESRecoveryPreparationService().capture(source: source, inputs: inputs, io: makeIO(source), progress: progress)
            directory = try await store.saveSNESPreparation(result)
        } catch let failure as SNESPreparationFailure {
            directory = try await store.saveSNESPreparationFailure(failure)
            throw SNESPreparationDiagnosticSavedError(directory: directory)
        }
        let values: [String: Any] = ["directory": directory.path, "complete": true, "USBOpened": true,
            "firmwareWritten": false, "firmwareRestoreEligible": false,
            "status": "Original recovery files checked in temporary memory and startup requirements saved on this Mac. Nothing was installed. Return to normal boot and check a built-in game."]
        return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
