import Foundation
import SWCompression
import SwiftHakchiCore

enum ConsoleGameImporter {
    static func importGame(code: String, storage: String, desktop: Data, destination: URL, shell: any ConsoleShell) async throws -> URL {
        guard SyncPlanner.validCode(code), !code.hasPrefix("CLV-S-"), storage.hasPrefix("/var/lib/hakchi/games/"),
              storage.hasSuffix("/.storage"), !(storage as NSString).pathComponents.contains("..") else {
            throw SyncPlanError.invalidInput("The console game storage path could not be validated.")
        }
        let tar = "tar -c -C \(LaunchCommand.shellQuote(storage)) \(LaunchCommand.shellQuote(code))"
        let archive = try await shell.executeChecked(tar, timeout: 300_000).stdoutData
        let expected = try await shell.executeChecked("set -o pipefail; \(tar) | sha256sum", timeout: 300_000).output.split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard expected == BackupManifest.digest(archive) else { throw SyncPlanError.invalidInput("Console game checksum verification failed: \(code)") }
        let entries = try TarContainer.open(container: archive)
        var files: [String: Data] = [:]
        for entry in entries {
            let components = entry.info.name.split(separator: "/").map(String.init)
            guard components.first == code, !components.contains(".."), !components.contains("."),
                  !entry.info.name.hasPrefix("/"), !entry.info.name.contains("\\"),
                  !entry.info.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  entry.info.type == .directory || entry.info.type == .regular else {
                throw SyncPlanError.invalidInput("Console game archive contains an unsupported path or link.")
            }
            if entry.info.type == .regular {
                let relative = components.dropFirst().joined(separator: "/")
                guard !relative.isEmpty, files[relative] == nil, let data = entry.data else { throw SyncPlanError.invalidInput("Console game archive contains duplicate or missing files.") }
                files[relative] = data
            }
        }
        guard files.contains(where: { ["nes", "fds", "sfc", "smc", "sfrom", "zip", "7z"].contains(($0.key as NSString).pathExtension.lowercased()) && !$0.value.isEmpty }) else {
            throw SyncPlanError.missingFile("The console archive contains no ROM for \(code)")
        }
        files[code + ".desktop"] = files[code + ".desktop"] ?? desktop
        let final = destination.appendingPathComponent(code, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: final.path) else { throw SyncPlanError.invalidInput("A local copy of \(code) already exists; it was not overwritten.") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for (relative, data) in files {
                let file = staging.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                guard BackupManifest.digest(try Data(contentsOf: file)) == BackupManifest.digest(data) else { throw SyncPlanError.invalidInput("Local game verification failed.") }
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: final)
            return final
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
}
