import Foundation
import SwiftHakchiCore

enum SNESRAMProbeDiagnosticOptions: Equatable, Sendable {
    case capture(String, String), prepare(String, String, String, String, String, String), test(String)
    static func parseIfPresent(_ args: [String]) throws -> Self? {
        guard let option = args.first, ["--capture-snes-runtime", "--prepare-snes-ram-probe", "--test-snes-ram-probe"].contains(option) else { return nil }
        let count = option == "--capture-snes-runtime" ? 3 : (option == "--prepare-snes-ram-probe" ? 7 : 2)
        guard args.count == count, args.dropFirst().allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
            throw RecoveryProbeError.refused("Usage: --capture-snes-runtime /setup /existing/Backups; --prepare-snes-ram-probe /setup /runtime /kernel /hmod /busybox /existing/Backups; --test-snes-ram-probe /reviewed/probe. These modes never install firmware.")
        }
        switch option {
        case "--capture-snes-runtime": return .capture(args[1], args[2])
        case "--prepare-snes-ram-probe": return .prepare(args[1], args[2], args[3], args[4], args[5], args[6])
        default: return .test(args[1])
        }
    }
}
enum SNESRAMProbeDiagnostic {
    /// Validate disk material before host ownership or USB construction. The prepare mode is entirely offline.
    static func runIfPresent(_ args: [String],
        loadInputs: @Sendable () async throws -> RecoveryBootInputs = { try await PayloadService.shared.pinnedRecoveryInputs() },
        checkHost: @Sendable () async throws -> Void = { try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makeCaptureIO: @Sendable () -> any RecoveryProbeIO = { NativeRecoveryProbeIO(observationCommand: SNESBackupPolicy.command) },
        makeProbeIO: @Sendable (PreparedSNESRAMProbe) -> any SNESRAMProbeIO = { NativeSNESRAMProbeIO(probe: $0) },
        progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String? {
        guard let mode = try SNESRAMProbeDiagnosticOptions.parseIfPresent(args) else { return nil }
        try Task.checkCancellation()
        let destination: URL
        var values: [String: Any] = ["firmwareRestoreEligible": false, "firmwareWritten": false]
        switch mode {
        case .capture(let setup, let root):
            let source = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: setup))
            let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: root))
            let inputs = try await loadInputs(); _ = try inputs.prepare()
            try source.revalidate(); try await checkHost(); try Task.checkCancellation()
            let runtime = try await SNESRuntimeCaptureService().capture(binding: source.runtimeBinding,
                inputs: inputs, io: makeCaptureIO(), progress: progress)
            destination = try await store.saveSNESRuntime(runtime, source: source)
            _ = try SNESRuntimeMaterial.load(directory: destination, source: source)
            values["status"] = "Original SNES runtime libraries saved and verified on this Mac. Return the console to normal boot."
            values["USBOpened"] = true
        case .prepare(let setup, let runtimePath, let kernel, let hmod, let busybox, let root):
            let source = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: setup))
            let runtime = try SNESRuntimeMaterial.load(directory: URL(fileURLWithPath: runtimePath), source: source)
            let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: root))
            func read(_ path: String) throws -> Data {
                let url = URL(fileURLWithPath: path)
                return try RestoreDirectory(url.deletingLastPathComponent()).read(url.lastPathComponent)
            }
            let inputs = try await loadInputs()
            let probe = try SNESRAMProbeRecipe.prepare(source: source, runtime: runtime, kernel: read(kernel),
                hmod: read(hmod), busybox: read(busybox), recovery: inputs, nonce: UUID().uuidString)
            destination = try await store.saveSNESProbe(probe)
            _ = try SNESRAMProbeRecipe.load(directory: destination, recovery: inputs)
            values["candidateSHA256"] = BackupManifest.digest(probe.image)
            values["candidateBytes"] = probe.image.count
            values["USBOpened"] = false
            values["status"] = "Isolated temporary startup files prepared on this Mac. They require a separate supervised RAM test; they are not an installer."
        case .test(let path):
            let inputs = try await loadInputs()
            let probe = try SNESRAMProbeRecipe.load(directory: URL(fileURLWithPath: path), recovery: inputs)
            let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: path).deletingLastPathComponent())
            try probe.validateCurrent(); try await checkHost(); try Task.checkCancellation()
            let result = try await SNESRAMProbeService().run(expected: probe.expectation, io: makeProbeIO(probe), progress: progress)
            destination = try await store.saveSNESProbeResult(result, probe: probe)
            values["candidateSHA256"] = BackupManifest.digest(probe.image)
            values["USBOpened"] = true
            values["status"] = "Isolated SNES startup report verified twice and saved on this Mac. Return the console to normal boot and test a built-in game."
        }
        values["directory"] = destination.path
        return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
