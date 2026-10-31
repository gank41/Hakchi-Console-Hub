import Foundation
import SWCompression
import SwiftHakchiCore

enum LegacyConsoleService {
    static func inspect(client: any LegacyRequestExecuting) async throws -> LegacyConsoleReport {
        try await LegacyConsoleReport.parse(checked(.report, client: client).stdoutData)
    }
    static func games(client: any LegacyRequestExecuting, report: LegacyConsoleReport) async throws -> [Game] {
        let data = try await checked(.metadata, client: client, timeout: 60_000).stdoutData
        try validateMetadataContainer(data)
        let entries = try TarContainer.open(container: data)
        var stock: [String: Game] = [:], pageStock: [String: Game] = [:], custom: [String: Game] = [:]
        var paths = Set<String>()
        var customMetadata: [String: Data] = [:]
        let factory = String(LegacyConsoleReport.factoryRoot.dropFirst())
        let base = String(LegacyConsoleReport.gameRoot.dropFirst())
        for entry in entries {
            try Task.checkCancellation()
            let name = entry.info.name
            let components = name.split(separator: "/").map(String.init)
            guard !name.hasPrefix("/"), !name.contains("\\"), !components.contains(".."), !components.contains("."),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw LegacyInspectionError.invalidMetadata }
            if entry.info.type == .directory { continue }
            guard entry.info.type == .regular, paths.insert(name).inserted, components.count >= 2, let content = entry.data else { throw LegacyInspectionError.invalidMetadata }
            let code = components[components.count - 2]
            guard components.last == code + ".desktop" else { throw LegacyInspectionError.invalidMetadata }
            let isStock = name == factory + "/" + code + "/" + code + ".desktop"
            let page = components.count == 8 ? components[5] : ""
            let isLegacy = page.range(of: #"^[0-9]{3}$"#, options: .regularExpression) != nil && name == base + "/" + page + "/" + code + "/" + code + ".desktop"
            guard isStock || isLegacy else { throw LegacyInspectionError.invalidMetadata }
            // Factory images also include auxiliary launchers such as PRODUCTION-TESTS.
            guard code.hasPrefix("CLV-") else { continue }
            guard SyncPlanner.validCode(code) else { throw LegacyInspectionError.invalidMetadata }
            if code.hasPrefix("CLV-S-") { continue }
            let desktop = DesktopFile(data: content)
            guard (desktop.code.isEmpty || desktop.code == code), !desktop.exec.isEmpty else { throw LegacyInspectionError.invalidMetadata }
            let source: GameSource = (isStock || report.stockCodes.contains(code)) ? .stock : .console
            var game = Game(code: code, desktopContent: String(decoding: content, as: UTF8.self), consoleType: .nes, source: source)
            game.isOnConsole = report.visibleCodes.contains(code); game.isSelected = game.isOnConsole
            if isStock {
                guard report.stockCodes.contains(code) else { throw LegacyInspectionError.invalidMetadata }
                stock[code] = game
            } else if report.stockCodes.contains(code) {
                guard pageStock[code] == nil else { throw LegacyInspectionError.invalidMetadata }
                pageStock[code] = game
            } else {
                if let existing = customMetadata[code], existing != content { throw LegacyInspectionError.invalidMetadata }
                customMetadata[code] = content; custom[code] = game
            }
        }
        guard Set(stock.keys) == report.stockCodes,
              report.visibleCodes.subtracting(report.stockCodes).isSubset(of: Set(custom.keys)) else { throw LegacyInspectionError.invalidMetadata }
        let displayedStock = Set(pageStock.keys) == report.stockCodes ? pageStock : stock
        return (Array(displayedStock.values) + Array(custom.values)).sorted { ($0.name, $0.code) < ($1.name, $1.code) }
    }
    static func backup(client: any LegacyRequestExecuting, report: LegacyConsoleReport, destination: URL,
                       progress: @Sendable (String, Double) -> Void = { _, _ in }) async throws -> URL {
        do {
            return try await backupAttempt(client: client, report: report, destination: destination, progress: progress)
        } catch LegacyInspectionError.archiveChanged(_) {
            // The running menu can flush its settings between the archive read
            // and independent hash. Re-read once; neither mismatched download
            // becomes a recovery backup. Never repeat a write or a USB failure.
            try Task.checkCancellation()
            progress("Console settings changed during the backup. Checking a fresh copy…", 0)
            return try await backupAttempt(client: client, report: report, destination: destination, progress: progress)
        }
    }

    private static func backupAttempt(client: any LegacyRequestExecuting, report: LegacyConsoleReport, destination: URL,
                                      progress: @Sendable (String, Double) -> Void) async throws -> URL {
        let fresh = try await inspect(client: client)
        guard report.matchesLayout(of: fresh) else { throw LegacyInspectionError.invalidBackup }
        let identityBefore = try? await LegacyDeviceIdentity.read(client: client)
        progress("Reading legacy games, original games and saves...", 0.05)
        let archive = try await checked(.backup, client: client, timeout: 300_000).stdoutData
        try Task.checkCancellation()
        // Retain failed downloads as explicitly unverified diagnostics, never as a restore input.
        let directory = destination.appendingPathComponent("LegacyInspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent("console.tar.partial")
        try archive.write(to: partial, options: .atomic)
        let actualDigest = BackupManifest.digest(archive)
        progress("Checking independent console archive hash...", 0.7)
        let expected = try await checked(.backupDigest, client: client, timeout: 300_000).output.split(whereSeparator: \.isWhitespace).first.map(String.init)
        let diagnostics: [String: Any] = ["verified": false, "receivedBytes": archive.count, "localSHA256": actualDigest, "remoteSHA256": expected ?? "missing"]
        try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("verification.json"), options: .atomic)
        guard archive.count >= 1024, archive.count % 512 == 0, expected == actualDigest else { throw LegacyInspectionError.archiveChanged(archive.count) }
        let after = try await inspect(client: client)
        guard report.matchesLayout(of: after) else { throw LegacyInspectionError.invalidBackup }
        let identityAfter = try? await LegacyDeviceIdentity.read(client: client)
        let file = partial
        guard BackupManifest.digest(try Data(contentsOf: file)) == expected else { throw LegacyInspectionError.invalidBackup }
        let listingURL = directory.appendingPathComponent("archive-contents.txt")
        FileManager.default.createFile(atPath: listingURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: listingURL)
        defer { try? handle.close() }
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-tf", file.path]; tar.standardOutput = handle; tar.standardError = FileHandle.nullDevice
        try tar.run(); tar.waitUntilExit(); try handle.close()
        guard tar.terminationStatus == 0 else { throw LegacyInspectionError.invalidBackup }
        let entries = try String(contentsOf: listingURL, encoding: .utf8).split(separator: "\n").map(String.init)
        let roots = ["/var/lib/hakchi", report.savesPath, LegacyConsoleReport.factoryRoot]
        guard roots.allSatisfy({ root in entries.contains { $0 == String(root.dropFirst()) || $0.hasPrefix(String(root.dropFirst()) + "/") } }),
              report.stockCodes.allSatisfy({ code in entries.contains { $0.hasPrefix(String(LegacyConsoleReport.factoryRoot.dropFirst()) + "/" + code + "/") && $0.hasSuffix(".nes") } }) else { throw LegacyInspectionError.invalidBackup }
        try Task.checkCancellation()
        let manifest = LegacyInspectionBackupManifest(createdAt: Date(), sourcePaths: roots, byteCount: archive.count, sha256: BackupManifest.digest(archive), observedReport: fresh)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.moveItem(at: partial, to: directory.appendingPathComponent("console.tar"))
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("verification.json"))
        if let identityBefore, identityBefore == identityAfter,
           let snapshot = try? LegacyMenuSnapshot.record(directory: directory, chipID: identityBefore),
           (try? LegacyMenuSnapshot.verify(directory: directory,
                expectedChipID: identityBefore).menuTreeSHA256) == snapshot.menuTreeSHA256 {
            progress("Console backup verified for saved-menu restore", 1)
        } else {
            progress("Legacy backup verified — inspection only", 1)
        }
        return directory
    }
    /// The fixed metadata command produces short regular-file entries. Reject extensions
    /// before SWCompression, whose extended-header decoder can trap on truncated payloads.
    private static func validateMetadataContainer(_ data: Data) throws {
        guard data.count >= 1024, data.count <= LegacyReadRequest.metadata.maximumOutputBytes,
              data.count % 512 == 0 else { throw LegacyInspectionError.invalidMetadata }
        let bytes = Array(data)
        var offset = 0
        while offset <= bytes.count - 512 {
            let header = bytes[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) {
                guard bytes.count - offset >= 1024, bytes[offset...].allSatisfy({ $0 == 0 }) else { throw LegacyInspectionError.invalidMetadata }
                return
            }
            guard [0, 48, 53].contains(bytes[offset + 156]),
                  let sizeText = String(bytes: bytes[(offset + 124)..<(offset + 136)], encoding: .ascii)?.trimmingCharacters(in: CharacterSet(charactersIn: " \0")),
                  !sizeText.isEmpty, sizeText.utf8.allSatisfy({ (48...55).contains($0) }),
                  let size = Int(sizeText, radix: 8), size >= 0, size <= bytes.count - offset - 512 else { throw LegacyInspectionError.invalidMetadata }
            // Size is bounded by the 16 MiB container, so padding arithmetic cannot overflow.
            let paddedSize = ((size + 511) / 512) * 512
            guard paddedSize <= bytes.count - offset - 512 else { throw LegacyInspectionError.invalidMetadata }
            offset += 512 + paddedSize
        }
        throw LegacyInspectionError.invalidMetadata
    }

    private static func checked(_ request: LegacyReadRequest, client: any LegacyRequestExecuting, timeout: Int = 30_000) async throws -> SSHResult {
        try Task.checkCancellation()
        let result = try await client.execute(request, timeoutMilliseconds: timeout)
        guard result.succeeded else { throw SSHError.commandFailed(command: "Legacy read-only " + String(describing: request), exitCode: result.exitCode, stderr: result.stderr) }
        try Task.checkCancellation()
        return result
    }
}

