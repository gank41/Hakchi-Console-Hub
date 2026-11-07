import Foundation

enum SNESOriginalMenuDiagnostic {
    static func runIfPresent(_ args: [String],
        loadInputs: @Sendable () async throws -> RecoveryBootInputs = { try PayloadService.shared.pinnedRecoveryInputs() },
        checkHost: @Sendable () async throws -> Void = { try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makeIO: @Sendable (PreparedSNESOriginalMenu) -> any SNESOriginalMenuIO = { NativeSNESOriginalMenuIO(menu: $0) },
        progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String? {
        guard let action = args.first, ["--prepare-original-snes-menu", "--test-original-snes-menu", "--check-original-snes-menu", "--capture-original-snes-startup"].contains(action) else { return nil }
        let count = action == "--prepare-original-snes-menu" ? 9 : (["--test-original-snes-menu", "--capture-original-snes-startup"].contains(action) ? 3 : 4)
        guard args.count == count, args.dropFirst().allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
            throw RecoveryProbeError.refused("Original SNES test paths are missing or invalid. This test does not install firmware.")
        }
        try Task.checkCancellation(); await progress(.checkingMaterial)
        func url(_ index: Int) -> URL { URL(fileURLWithPath: args[index]) }
        if action == "--prepare-original-snes-menu" {
            let setup = try SNESOfflineSource.load(snapshot: url(1))
            let prep = try SNESMenuSupportSource.load(setup: setup, preparation: url(2))
            let support = try SNESMenuSupportMaterial.load(source: prep, directory: url(3))
            let components = try SNESOriginalComponentMaterial.load(source: SNESOriginalComponentSource(material: support), directory: url(4))
            let runtime = try SNESRuntimeMaterial.load(directory: url(5), source: setup)
            let material = try SNESOriginalMenuMaterial(components: components, runtime: runtime)
            let hmod = try RestoreDirectory(url(6).deletingLastPathComponent()).read(url(6).lastPathComponent, maximum: 1024*1024)
            let bb = try RestoreDirectory(url(7).deletingLastPathComponent()).read(url(7).lastPathComponent, maximum: 2*1024*1024)
            let store = try RecoveryBootSnapshotStore(root: url(8)), inputs = try await loadInputs()
            try material.revalidate()
            let menu = try SNESOriginalMenuRecipe.prepare(material: material, daemonHmod: hmod, busybox: bb, recovery: inputs)
            let directory = try await store.saveSNESOriginalMenu(menu)
            _ = try SNESOriginalMenuRecipe.load(directory: directory, recovery: inputs)
            return try json(directory: directory, status: "Temporary SNES test files prepared on this Mac. The console was not started.")
        }
        // Missing storage/source refuses before recovery payload loading or USB construction.
        _ = try RestoreDirectory(url(1))
        let store = try RecoveryBootSnapshotStore(root: url(count-1)), inputs = try await loadInputs()
        let menu = try SNESOriginalMenuRecipe.load(directory: url(1), recovery: inputs)
        let started = action == "--check-original-snes-menu" ? try SNESOriginalMenuResult.loadStarted(directory: url(2), menu: menu) : nil
        try menu.validateCurrent(); try await checkHost(); try Task.checkCancellation(); try menu.validateCurrent()
        let service = SNESOriginalMenuService(), io = makeIO(menu)
        var completed: SNESOriginalMenuResult?
        var captured: SNESStartupCapture?
        do {
            if action == "--capture-original-snes-startup" {
                let result = try await service.captureStartup(menu: menu, store: store, io: io, progress: progress)
                captured = result
                let directory = try await store.saveSNESStartupCapture(result, menu: menu)
                return try json(directory: directory, status: "Startup details saved on this Mac. The menu was not launched. Return the console to normal startup when instructed.")
            }
            let result: SNESOriginalMenuResult
            if let started { result = try await service.check(menu: menu, started: started, store: store, io: io, progress: progress) }
            else { result = try await service.start(menu: menu, store: store, io: io, progress: progress) }
            completed = result
            let directory = try await store.saveSNESOriginalMenuResult(result, menu: menu)
            return try json(directory: directory, status: "The temporary SNES connection passed its machine checks. Check the TV, sound, controls and a built-in game. Nothing was installed.")
        } catch {
            if error is RecoverySnapshotCleanupError { throw error }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure: SNESOriginalMenuFailure
            if let existing = error as? SNESOriginalMenuFailure { failure = existing }
            else if let captured { failure = .init(stage: "saving-startup-details", report: captured.checkpoint.report, diagnostics: captured.diagnostics, checkpoint: captured.checkpoint) }
            else if let completed { failure = .init(stage: "saving-result", report: completed.reports.last ?? Data(), diagnostics: completed.diagnostics, checkpoint: completed.checkpoint, capturedReports: completed.reports) }
            else { throw error }
            let directory = try await store.saveSNESOriginalMenuFailure(failure, menu: menu)
            throw SNESPreparationDiagnosticSavedError(directory: directory)
        }
    }
    private static func json(directory: URL, status: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["directory": directory.path, "complete": true,
            "firmwareWritten": false, "firmwareRestoreEligible": false, "userGameplayConfirmed": false, "status": status],
            options: [.prettyPrinted,.sortedKeys]), as: UTF8.self)
    }
}
