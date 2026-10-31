import Foundation
import SwiftHakchiCore

struct VerifiedConsoleBackup: Sendable {
    let manifest: BackupManifest
    let directory: URL
}

enum ConsoleBackupService {
    /// Read-only export: no temporary archive is written into the console's RAM or storage.
    static func backup(inventory: DeviceInventory, shell: any ConsoleShell, destination: URL,
                       progress: @Sendable (String, Double) -> Void = { _, _ in }) async throws -> VerifiedConsoleBackup {
        guard inventory.canSync, let base = inventory.syncBase else { throw SyncPlanError.unsupportedConsole }
        _ = try await shell.executeChecked("command -v sha256sum")
        let originalGames = "/var/squashfs" + inventory.originalGamesPath
        _ = try await shell.executeChecked("test -d \(LaunchCommand.shellQuote(originalGames))")
        var paths = [base, originalGames]
        for path in ["/var/saves", "/var/lib/hakchi/config", "/hakchi/config"] {
            let result = try await shell.execute("test -d \(LaunchCommand.shellQuote(path)) -o -f \(LaunchCommand.shellQuote(path))", timeout: 30_000)
            guard result.exitCode == 0 || result.exitCode == 1 else {
                throw SyncPlanError.invalidInput("Could not inspect backup source: \(path)")
            }
            if result.succeeded { paths.append(path) }
        }
        // /var/saves is a symlink on hakchi. Archive its canonical target, not the link.
        paths = try await paths.asyncResolved(shell: shell)
        let arguments = paths.map { LaunchCommand.shellQuote(String($0.dropFirst())) }.joined(separator: " ")
        let tar = "tar -c -C / \(arguments)"
        progress("Reading console backup...", 0.1)
        let archive = try await shell.executeChecked("set -o pipefail; \(tar)", timeout: 300_000).stdoutData
        try Task.checkCancellation()
        progress("Verifying console backup...", 0.7)
        let remoteDigest = try await shell.executeChecked("set -o pipefail; \(tar) | sha256sum", timeout: 300_000).output.split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard remoteDigest == BackupManifest.digest(archive), archive.count >= 1024, archive.count % 512 == 0 else {
            throw SyncPlanError.invalidInput("The console backup was incomplete or changed during export. Nothing has been replaced; retry after stopping gameplay.")
        }
        let directory = destination.appendingPathComponent(inventory.profile.storageKey).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("console.tar")
        do {
            try archive.write(to: archiveURL, options: .atomic)
            let manifest = BackupManifest(profile: inventory.profile, sourcePaths: paths, archiveFilename: "console.tar", data: archive)
            try manifest.verify(archive: Data(contentsOf: archiveURL), for: inventory.profile)
            let validation = Process()
            validation.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            validation.arguments = ["-tf", archiveURL.path]
            let listingURL = directory.appendingPathComponent("archive-contents.txt")
            FileManager.default.createFile(atPath: listingURL.path, contents: nil)
            let listing = try FileHandle(forWritingTo: listingURL)
            validation.standardOutput = listing
            validation.standardError = FileHandle.nullDevice
            try validation.run(); validation.waitUntilExit(); try listing.close()
            guard validation.terminationStatus == 0 else { throw SyncPlanError.invalidInput("The downloaded backup is not a readable archive.") }
            let entries = try String(contentsOf: listingURL, encoding: .utf8).split(separator: "\n").map(String.init)
            guard paths.allSatisfy({ path in
                let relative = String(path.dropFirst())
                return entries.contains { $0 == relative || $0.hasPrefix(relative + "/") }
            }) else { throw SyncPlanError.invalidInput("The backup archive is missing an expected source directory.") }
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            progress("Console backup verified", 1)
            return VerifiedConsoleBackup(manifest: manifest, directory: directory)
        } catch {
            // Keep partial data for diagnosis, but never leave a verified manifest.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("manifest.json"))
            throw error
        }
    }

    static func verify(_ backup: VerifiedConsoleBackup, for inventory: DeviceInventory) throws {
        try backup.manifest.verify(archive: Data(contentsOf: backup.directory.appendingPathComponent(backup.manifest.archiveFilename)), for: inventory.profile)
    }
}

private extension Array where Element == String {
    func asyncResolved(shell: any ConsoleShell) async throws -> [String] {
        var resolved: [String] = []
        for path in self {
            let target = try await shell.executeChecked("readlink -f \(LaunchCommand.shellQuote(path))").output
            guard target.hasPrefix("/"), target != "/", !target.contains("\n"),
                  !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !(target as NSString).pathComponents.contains("..") else {
                throw SyncPlanError.invalidInput("Could not resolve backup source: \(path)")
            }
            if !resolved.contains(target) { resolved.append(target) }
        }
        return resolved
    }
}
