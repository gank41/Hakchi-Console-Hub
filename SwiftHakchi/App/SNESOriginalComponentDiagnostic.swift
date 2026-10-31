import Foundation

enum SNESOriginalComponentDiagnostic {
    static func runIfPresent(_ args: [String],
        loadInputs: @Sendable () async throws -> RecoveryBootInputs = { try PayloadService.shared.pinnedRecoveryInputs() },
        checkHost: @Sendable () async throws -> Void = { try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makeIO: @Sendable (SNESOriginalComponentSource) -> any SNESOriginalComponentIO = { NativeSNESOriginalComponentIO(source: $0) },
        progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String? {
        guard args.first == "--capture-snes-original-components" else { return nil }
        guard args.count == 5, args.dropFirst().allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
            throw RecoveryProbeError.refused("Usage: --capture-snes-original-components /setup /preparation /support /existing/Backups. This check does not install firmware.")
        }
        try Task.checkCancellation(); await progress(.checkingMaterial)
        let setup = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: args[1]))
        let prep = try SNESMenuSupportSource.load(setup: setup, preparation: URL(fileURLWithPath: args[2]))
        let source = try SNESOriginalComponentSource(material: SNESMenuSupportMaterial.load(source: prep, directory: URL(fileURLWithPath: args[3])))
        let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: args[4]))
        let inputs = try await loadInputs(); _ = try inputs.prepare()
        try source.revalidate(); try await checkHost(); try Task.checkCancellation(); try source.revalidate()
        let destination: URL
        var captured: SNESOriginalComponentResult?
        do {
            let result = try await SNESOriginalComponentService().capture(source: source, inputs: inputs, io: makeIO(source), progress: progress)
            captured = result
            destination = try await store.saveSNESOriginalComponents(result)
            _ = try SNESOriginalComponentMaterial.load(source: source, directory: destination)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure: SNESOriginalComponentFailure
            if let existing = error as? SNESOriginalComponentFailure { failure = existing }
            else if let captured { failure = .init(source: source, stage: "saving-result", frame: captured.frame.raw) }
            else { throw error }
            let path = try await store.saveSNESOriginalComponentFailure(failure)
            throw SNESPreparationDiagnosticSavedError(directory: path)
        }
        let values: [String: Any] = ["complete": true, "USBOpened": true, "directory": destination.path,
            "firmwareWritten": false, "firmwareRestoreEligible": false,
            "status": "Original SNES components checked and saved on this Mac. Nothing was installed. Return to normal startup and check a built-in game."]
        return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
