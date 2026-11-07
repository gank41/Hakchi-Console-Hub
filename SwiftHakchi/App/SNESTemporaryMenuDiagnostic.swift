import Foundation
import SwiftHakchiCore

enum SNESTemporaryMenuDiagnosticOptions: Equatable, Sendable {
    case prepare(String, String, String, String, String), test(String), check(String, String)
    static func parseIfPresent(_ args: [String]) throws -> Self? {
        guard let option = args.first, ["--prepare-snes-menu", "--test-snes-menu", "--check-snes-menu"].contains(option) else { return nil }
        let count = option == "--prepare-snes-menu" ? 6 : (option == "--test-snes-menu" ? 2 : 3)
        guard args.count == count, args.dropFirst().allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
            throw RecoveryProbeError.refused("Usage: --prepare-snes-menu /base-probe /preparation /support /drivers.hmod /existing/Backups; --test-snes-menu /prepared-menu; --check-snes-menu /prepared-menu /started-result. Temporary testing only; no firmware installation.")
        }
        switch option {
        case "--prepare-snes-menu": return .prepare(args[1], args[2], args[3], args[4], args[5])
        case "--test-snes-menu": return .test(args[1])
        default: return .check(args[1], args[2])
        }
    }
}
enum SNESTemporaryMenuDiagnostic {
    static func runIfPresent(_ args: [String],
        loadInputs: @Sendable () async throws -> RecoveryBootInputs = { try PayloadService.shared.pinnedRecoveryInputs() },
        checkHost: @Sendable () async throws -> Void = { try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makeIO: @Sendable (PreparedSNESTemporaryMenu) -> any SNESTemporaryMenuIO = { NativeSNESTemporaryMenuIO(menu: $0) },
        progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String? {
        guard let mode = try SNESTemporaryMenuDiagnosticOptions.parseIfPresent(args) else { return nil }
        try Task.checkCancellation()
        let inputs = try await loadInputs()
        let destination: URL, menu: PreparedSNESTemporaryMenu
        let status: String, usbOpened: Bool
        switch mode {
        case .prepare(let basePath, let prep, let supportPath, let driversPath, let root):
            let base = try SNESRAMProbeRecipe.load(directory: URL(fileURLWithPath: basePath), recovery: inputs)
            let supportSource = try SNESMenuSupportSource.load(setup: base.source, preparation: URL(fileURLWithPath: prep))
            let support = try SNESMenuSupportMaterial.load(source: supportSource, directory: URL(fileURLWithPath: supportPath))
            let driversURL = URL(fileURLWithPath: driversPath)
            let bytes = try RestoreDirectory(driversURL.deletingLastPathComponent()).read(driversURL.lastPathComponent, maximum: 100000)
            menu = try SNESTemporaryMenuRecipe.prepare(base: base, support: support, drivers: SNESMenuDrivers(bytes))
            destination = try await RecoveryBootSnapshotStore(root: URL(fileURLWithPath: root)).saveSNESTemporaryMenu(menu)
            _ = try SNESTemporaryMenuRecipe.load(directory: destination, recovery: inputs)
            status = "Temporary SNES menu files prepared on this Mac. A supervised RAM test is still required."
            usbOpened = false
        case .test(let path), .check(let path, _):
            menu = try SNESTemporaryMenuRecipe.load(directory: URL(fileURLWithPath: path), recovery: inputs)
            let started: SNESTemporaryMenuResult?
            if case .check(_, let receipt) = mode { started = try SNESTemporaryMenuResult.loadStarted(directory: URL(fileURLWithPath: receipt), menu: menu) }
            else { started = nil }
            let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: path).deletingLastPathComponent())
            try menu.validateCurrent(); try await checkHost(); try Task.checkCancellation(); try menu.validateCurrent()
            let service = SNESTemporaryMenuService(), io = makeIO(menu)
            var captured: SNESTemporaryMenuResult?
            do {
                let result: SNESTemporaryMenuResult
                if let started {
                    result = try await service.check(expected: menu.expectation, started: started, io: io,
                        validate: { try menu.validateCurrent() }, progress: progress)
                } else {
                    result = try await service.start(expected: menu.expectation, io: io,
                        validate: { try menu.validateCurrent() }, progress: progress)
                }
                captured = result
                destination = try await store.saveSNESTemporaryMenuResult(result, menu: menu)
            } catch {
                if error is RecoverySnapshotCleanupError { throw error }
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                let failure: SNESTemporaryMenuFailure
                if let existing = error as? SNESTemporaryMenuFailure { failure = existing }
                else if let captured {
                    failure = .init(stage: "saving-result", report: captured.reports.last ?? Data(), diagnostics: Data(), capturedReports: captured.reports)
                } else { throw error }
                let saved = try await store.saveSNESTemporaryMenuFailure(failure, menu: menu)
                throw RecoveryProbeError.refused("The temporary SNES check stopped. Private details: \(saved.path). Return the console to normal startup before another test.")
            }
            status = started == nil ? "Temporary menu and Mac reports verified. Gameplay and sound still need your check; leave the console powered on."
                : "The Mac connection still answers after gameplay. Return the console to normal startup and check its original menu and a game."
            usbOpened = true
        }
        let values: [String: Any] = ["directory": destination.path, "candidateSHA256": BackupManifest.digest(menu.image),
            "candidateBytes": menu.image.count, "USBOpened": usbOpened, "firmwareWritten": false,
            "firmwareRestoreEligible": false, "status": status]
        return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
