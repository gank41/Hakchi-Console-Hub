import Foundation

enum SNESMenuSupportDiagnostic {
    static func runIfPresent(_ args: [String],
        loadInputs: @Sendable () async throws -> RecoveryBootInputs = { try await PayloadService.shared.pinnedRecoveryInputs() },
        checkHost: @Sendable () async throws -> Void = { try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makeIO: @Sendable (SNESMenuSupportSource) -> any SNESMenuSupportIO = { NativeSNESMenuSupportIO(source: $0) },
        progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String? {
        guard args.first == "--capture-snes-menu-support" else { return nil }
        guard args.count == 4, args.dropFirst().allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
            throw RecoveryProbeError.refused("Usage: --capture-snes-menu-support /setup /completed/preparation /existing/Backups. This check does not install firmware.")
        }
        try Task.checkCancellation(); await progress(.checkingMaterial)
        let setup = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: args[1]))
        let source = try SNESMenuSupportSource.load(setup: setup, preparation: URL(fileURLWithPath: args[2]))
        let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: args[3]))
        let inputs = try await loadInputs(); _ = try inputs.prepare()
        try source.revalidate(); try await checkHost(); try Task.checkCancellation(); try source.revalidate()
        let destination: URL
        do {
            let result = try await SNESMenuSupportService().capture(source: source, inputs: inputs, io: makeIO(source), progress: progress)
            destination = try await store.saveSNESMenuSupport(result)
        } catch let failure as SNESMenuSupportFailure {
            let path = try await store.saveSNESMenuSupportFailure(failure)
            throw SNESPreparationDiagnosticSavedError(directory: path)
        }
        let values: [String: Any] = ["complete": true, "USBOpened": true, "directory": destination.path,
            "firmwareWritten": false, "firmwareRestoreEligible": false,
            "status": "Remaining startup files checked and saved on this Mac. Nothing was installed. Return to normal boot and check a built-in game."]
        return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
