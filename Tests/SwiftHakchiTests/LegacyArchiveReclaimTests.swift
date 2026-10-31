import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

private struct ReclaimFixtureDevice: LegacyArchiveReclaimDevice {
    let report: LegacyConsoleReport
    let operation: LegacySyncInspection
    let archive: LegacyArchiveReclaimCommands.Inspection
    func inspect() async throws -> LegacyConsoleReport { report }
    func requireIdentity() async throws {}
    func inspectOperation(operationID: UUID, treeSHA256: String) async throws -> LegacySyncInspection { operation }
    func inventoryLive(operationID: UUID) async throws -> Data { Data() }
    func inspectArchive(operationID: UUID, treeSHA256: String,
                        archiveSHA256: String, archiveBytes: Int64) async throws -> LegacyArchiveReclaimCommands.Inspection { archive }
    func removeArchive(operationID: UUID, treeSHA256: String,
                       archiveSHA256: String, archiveBytes: Int64) async throws {}
}

struct LegacyArchiveReclaimTests {
    private let id = UUID(uuidString: "0A74C2CE-3322-4ADC-9B57-E78F06899665")!
    private let archive = String(repeating: "a", count: 64)
    private let tree = String(repeating: "b", count: 64)

    @Test func exactAcceptedArchiveIsEligibleForPreview() throws {
        let response = "RECLAIM_ARCHIVE_V1\nID=\(id.uuidString)\nPHASE=ACCEPTED\nLIVE=1\nOLD=1\nLOCK=0\nARCHIVE=1\nBYTES=29977088\nSHA256=\(archive)\nTREE_SHA256=\(tree)\nEND\n"
        let result = try LegacyArchiveReclaimCommands.parseInspection(Data(response.utf8),
            operationID: id, archiveSHA256: archive, archiveBytes: 29_977_088,
            treeSHA256: tree)
        #expect(result.archivePresent)
        #expect(result.archiveBytes == 29_977_088)
    }

    @Test func changedOrMissingArchiveDoesNotPassPreview() {
        let changed = "RECLAIM_ARCHIVE_V1\nID=\(id.uuidString)\nPHASE=ACCEPTED\nLIVE=1\nOLD=1\nLOCK=0\nARCHIVE=1\nBYTES=29977088\nSHA256=\(String(repeating: "c", count: 64))\nTREE_SHA256=\(tree)\nEND\n"
        #expect(throws: (any Error).self) {
            try LegacyArchiveReclaimCommands.parseInspection(Data(changed.utf8),
                operationID: id, archiveSHA256: archive, archiveBytes: 29_977_088,
                treeSHA256: tree)
        }
        let absent = changed.replacingOccurrences(of: "ARCHIVE=1", with: "ARCHIVE=0")
        #expect(throws: (any Error).self) {
            try LegacyArchiveReclaimCommands.parseInspection(Data(absent.utf8),
                operationID: id, archiveSHA256: archive, archiveBytes: 29_977_088,
                treeSHA256: tree)
        }
    }

    @Test func previewRequiresMatchingLocalArchiveAndAcceptedRemoteOperation() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        let stage = workspace.root.appendingPathComponent("Stages", isDirectory: true)
            .appendingPathComponent("LegacyMenuStage-" + UUID().uuidString)
        let backup = workspace.backups.appendingPathComponent("LegacyInspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0, count: 1024)
        try bytes.write(to: stage.appendingPathComponent("menu.tar"))
        try bytes.write(to: backup.appendingPathComponent("console.tar"))
        let digest = BackupManifest.digest(bytes)
        try JSONSerialization.data(withJSONObject: ["sha256": digest, "byteCount": 1024])
            .write(to: backup.appendingPathComponent("manifest.json"))
        var record = try LegacySyncJournal(operationID: id, reviewSHA256: tree,
            archiveSHA256: digest, treeSHA256: tree, backupSHA256: digest,
            backupDirectory: backup, stageDirectory: stage, trialCode: "CLV-H-ABCDE",
            maximumGamesPerPage: 30, archiveBytes: 1024)
        record.phase = .accepted
        let report = LegacyConsoleReport(bootVersion: "1.0.1", kernelVersion: "3.4.112.madmonkey",
            scriptVersion: "[master]v1.0.3-110(7f31082)",
            activePage: "/var/lib/hakchi/games/nes/000", freeBytes: 170_000_000,
            savesPath: "/var/lib/clover/profiles/0",
            stockCodes: Set((0..<30).map { String(format: "CLV-P-%05d", $0) }),
            visibleCodes: ["CLV-H-ABCDE"])
        let device = ReclaimFixtureDevice(report: report,
            operation: LegacySyncInspection(phase: .accepted, live: true, old: true,
                                            stage: false, lock: false, archive: true),
            archive: .init(archivePresent: true, archiveBytes: 1024))

        let preview = try await LegacyArchiveReclaim.preview(record: record, workspace: workspace, device: device)
        #expect(preview.operationID == id)
        #expect(preview.archiveBytes == 1024)
        try Data(repeating: 1, count: 1024).write(to: stage.appendingPathComponent("menu.tar"))
        await #expect(throws: (any Error).self) {
            try await LegacyArchiveReclaim.preview(record: record, workspace: workspace, device: device)
        }
    }

    @Test func commandTargetsOnlyTheReviewedOperationsArchive() throws {
        let command = try LegacyChangeRequest.removeReclaimArchive(id, tree, archive, 29_977_088).command
        #expect(command.contains("/var/lib/hakchi/.swift-hakchi-sync-" + id.uuidString))
        #expect(command.contains("rm -- \"$tx/menu.tar\""))
        #expect(command.contains("$tx/verified.marker"))
        #expect(command.contains("$tx/old.identity"))
        #expect(command.contains("stat -c '%d:%i' \"$old\""))
        #expect(!command.contains("rm -rf"))
        #expect(!command.contains("/var/lib/hakchi/games/nes.swift-old-" + UUID().uuidString))
    }

    @Test func archiveRemovalDoesNotWaitForGlobalFilesystemFlush() throws {
        let command = try LegacyArchiveReclaimCommands.remove(operationID: id,
            treeSHA256: tree, archiveSHA256: archive, archiveBytes: 29_977_088)
        #expect(!command.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "sync" })
        let removal = command.range(of: "rm -- \"$tx/menu.tar\"")!
        let absence = command.range(of: "[ ! -e \"$tx/menu.tar\" ] && [ ! -L \"$tx/menu.tar\" ]")!
        let receipt = command.range(of: "RECLAIMED_ARCHIVE:")!
        #expect(removal.lowerBound < absence.lowerBound)
        #expect(absence.lowerBound < receipt.lowerBound)
    }

    @Test func generatedArchiveCommandsHaveValidShellSyntax() throws {
        let commands = [
            try LegacyArchiveReclaimCommands.inspect(operationID: id, treeSHA256: tree,
                                                      archiveSHA256: archive, archiveBytes: 29_977_088),
            try LegacyArchiveReclaimCommands.remove(operationID: id, treeSHA256: tree,
                                                     archiveSHA256: archive, archiveBytes: 29_977_088)
        ]
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n"]
            let input = Pipe()
            process.standardInput = input
            process.standardError = Pipe()
            try process.run()
            input.fileHandleForWriting.write(Data(command.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }

    @Test func bootRepairedPageFontsDoNotChangeTheAcceptedMenuDigest() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("000", isDirectory: true)
        try FileManager.default.createDirectory(at: page, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: page.appendingPathComponent("game.desktop"))
        let expected = "06c6f4009cc602b3dab87b24ec5fc0029d1c93aa3bb0bae551d9ac36c0cfdbc0"
        #expect(try digestOfGeneratedCommand(at: root) == expected)

        // The older hakchi boot repair copies these two fonts into every menu page.
        try Data("title".utf8).write(to: page.appendingPathComponent("title.fnt"))
        try Data("copyright".utf8).write(to: page.appendingPathComponent("copyright.fnt"))
        #expect(try digestOfGeneratedCommand(at: root) == expected)

        try Data("extra".utf8).write(to: page.appendingPathComponent("unexpected.txt"))
        #expect(try digestOfGeneratedCommand(at: root) != expected)
    }

    @Test func archivedPageFontsCanBeIncludedInTheAcceptedMenuDigest() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("000", isDirectory: true)
        try FileManager.default.createDirectory(at: page, withIntermediateDirectories: true)
        let files = ["copyright.fnt": "copyright", "game.desktop": "x", "title.fnt": "title"]
        for (name, value) in files {
            try Data(value.utf8).write(to: page.appendingPathComponent(name))
        }
        let descriptions = ["000\tdirectory\t0\t\t"] + files.keys.sorted().map { name in
            let data = Data(files[name]!.utf8)
            return "000/\(name)\tregular\t\(data.count)\t\(BackupManifest.digest(data))\t"
        }
        let expected = BackupManifest.digest(Data((descriptions.joined(separator: "\n") + "\n").utf8))
        #expect(try digestOfGeneratedCommand(at: root, includeFonts: true) == expected)
        #expect(try digestOfGeneratedCommand(at: root) != expected)
    }

    @Test func unsafeBootFontCannotBeIgnoredByArchiveCheck() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("000", isDirectory: true)
        try FileManager.default.createDirectory(at: page, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: page.appendingPathComponent("game.desktop"))
        try FileManager.default.createSymbolicLink(at: page.appendingPathComponent("title.fnt"),
                                                    withDestinationURL: page.appendingPathComponent("game.desktop"))
        #expect(throws: (any Error).self) { try digestOfGeneratedCommand(at: root) }
        try FileManager.default.removeItem(at: page.appendingPathComponent("title.fnt"))
        try Data(repeating: 0, count: 1_048_577).write(to: page.appendingPathComponent("title.fnt"))
        #expect(throws: (any Error).self) { try digestOfGeneratedCommand(at: root) }
    }

    private func digestOfGeneratedCommand(at directory: URL, includeFonts: Bool = false) throws -> String {
        let command = try LegacyArchiveReclaimCommands.inspect(operationID: id, treeSHA256: tree,
                                                                 archiveSHA256: archive, archiveBytes: 29_977_088)
        let start = command.range(of: "tree_digest() {")!.lowerBound
        let end = command.range(of: "\ncanonical \"$base\"", range: start..<command.endIndex)!.lowerBound
        let function = String(command[start..<end])
        let script = """
        set -eu
        set -o pipefail
        PATH=/bin:/sbin:/usr/bin:/usr/sbin; export PATH
        stat() { [ "$1" = -c ] && [ "$2" = %s ] || exit 99; /usr/bin/stat -f %z "$3"; }
        \(function)
        tree_digest \(LaunchCommand.shellQuote(directory.path)) \(includeFonts ? "include" : "ignore")
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LegacyInspectionError.invalidResponse }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
