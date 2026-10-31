import Foundation
import SwiftHakchiCore

enum SNESOfflineBuildOptions: Equatable, Sendable {
    case inspect(String), build(String, String, String), prepareRecovery(String, String)
    static func parseIfPresent(_ args: [String]) throws -> Self? {
        guard let option = args.first, ["--inspect-snes-image", "--build-snes-image", "--prepare-snes-recovery"].contains(option) else { return nil }
        let count = option == "--inspect-snes-image" ? 2 : (option == "--prepare-snes-recovery" ? 3 : 4)
        guard args.count == count, args.dropFirst().allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
            throw RecoveryProbeError.refused("Usage: --inspect-snes-image /snapshot or --build-snes-image /snapshot /kernel /existing/Backups. or --prepare-snes-recovery /snapshot /existing/Backups. These commands work on Mac files only.")
        }
        if option == "--prepare-snes-recovery" { return .prepareRecovery(args[1], args[2]) }
        return count == 2 ? .inspect(args[1]) : .build(args[1], args[2], args[3])
    }
}

enum SNESOfflineBuildDiagnostic {
    /// Main uses this same dispatcher: failures in an offline mode never enter the hardware closure.
    static func dispatch(_ arguments: [String], progress: @Sendable (String) -> Void = { _ in },
                         online: @MainActor @Sendable () async throws -> Void) async throws {
        if let result = try await SNESStartupPreparationDiagnostic.runIfPresent(arguments) { print(result); return }
        guard let mode = try SNESOfflineBuildOptions.parseIfPresent(arguments) else { try await online(); return }
        let snapshot: String
        switch mode { case .inspect(let p), .build(let p, _, _), .prepareRecovery(let p, _): snapshot = p }
        progress("Reading the saved SNES backup on this Mac…")
        let source = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: snapshot))
        progress("Checking startup files…")
        let inspected = try LegacyBootImageBuilder.inspect(source.stock)
        var result: [String: Any] = ["USBOpened": false, "bootEligible": false, "firmwareRestoreEligible": false,
            "stockSHA256": BackupManifest.digest(source.stock), "members": inspected.archive.entries.count,
            "status": "Startup archive checked on this Mac. Nothing was sent to the console."]
        if case .build(_, let kernelPath, let root) = mode {
            let kernelDirectory = try RestoreDirectory(URL(fileURLWithPath: kernelPath).deletingLastPathComponent())
            let kernel = try kernelDirectory.read(URL(fileURLWithPath: kernelPath).lastPathComponent)
            progress("Building the experimental startup image…")
            let build = try SNESOfflineImageBuild.make(source: source, kernel: kernel)
            progress("Verifying the image and saving it on this Mac…")
            let destination = try await RecoveryBootSnapshotStore(root: URL(fileURLWithPath: root)).saveSNESBuild(build)
            result["buildDirectory"] = destination.path
            result["candidateSHA256"] = BackupManifest.digest(build.image)
            result["candidateBytes"] = build.image.count
            result["status"] = "Experimental startup files built, verified and saved on this Mac. They are not approved for booting or installation."
        }
        if case .prepareRecovery(_, let root) = mode {
            progress("Preparing this console’s recovery backup…")
            let material = try SNESRecoveryMaterial.load(setup: URL(fileURLWithPath: snapshot))
            let destination = try await RecoveryBootSnapshotStore(root: URL(fileURLWithPath: root)).saveSNESRecoveryMaterial(material)
            _ = try SNESRecoveryMaterial.loadPackage(directory: destination)
            result["recoveryDirectory"] = destination.path
            result["firmwareWritten"] = false
            result["status"] = "Recovery backup prepared and checked on this Mac. No console changes were made."
        }
        progress("Finished. The console was not changed.")
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
