import Foundation
import CryptoKit
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

actor InventoryShell: ConsoleShell {
    var system = "clv-nes"
    var identity = "ABC123"
    var active = "/var/lib/hakchi/games/nes-usa/000"
    var capacity = "/dev/nandc 400000 100000 300000 25% /var/lib"
    var archive: Data = {
        var tar = TarWriter()
        for path in ["var/squashfs/usr/share/games/nes/kachikachi/factory.nes", "var/saves/game.dat", "var/lib/hakchi/games/nes-usa/000/game.dat", "var/lib/hakchi/config/settings", "hakchi/config/settings"] {
            tar.addFile(name: path, contents: Data([0, 1, 255, 0, 2]))
        }
        return tar.finalize()
    }()
    var corruptDigest = false
    func set(system: String? = nil, identity: String? = nil, active: String? = nil, capacity: String? = nil, corrupt: Bool = false) {
        if let system { self.system = system }; if let identity { self.identity = identity }
        if let active { self.active = active }; if let capacity { self.capacity = capacity }; corruptDigest = corrupt
    }
    func execute(_ command: String, timeout: Int) async throws -> SSHResult {
        let text: String
        switch command {
        case DeviceInventoryService.Command.identity: text = identity
        case DeviceInventoryService.Command.system: text = system
        case DeviceInventoryService.Command.activePage: text = active
        case DeviceInventoryService.Command.capacity: text = capacity
        case DeviceInventoryService.Command.version: text = "1.0.3 3.4.113 1.0.4.124"
        default:
            if command.hasPrefix("readlink -f ") { text = try LaunchCommand.arguments(in: command).last! }
            else if command.contains("-maxdepth 2") { text = "CLV-P-NAAAE\nCLV-H-AAAAA\nCLV-H-BBBBB" }
            else if command.hasPrefix("find ") { text = "CLV-H-AAAAA\nCLV-H-BBBBB" }
            else if command.hasPrefix("test -d ") || command.hasPrefix("command -v ") { text = "yes" }
            else if command.contains("sha256sum") {
                text = corruptDigest ? String(repeating: "0", count: 64) : SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
            } else if command.hasPrefix("set -o pipefail; tar -c ") {
                return SSHResult(stdout: "", stderr: "", stdoutData: archive, exitCode: 0)
            } else { throw SSHError.commandFailed(command: command, exitCode: 127, stderr: "unexpected test command") }
        }
        return SSHResult(stdout: text, stderr: "", stdoutData: Data(text.utf8), exitCode: 0)
    }
    func upload(data: Data, to remotePath: String, timeout: Int) async throws { Issue.record("Inventory/backup must not upload") }
    func uploadTar(data: Data, to directory: String, extraArgs: String, timeout: Int) async throws { Issue.record("Inventory/backup must not extract") }
}

func testDirectory() throws -> URL {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = repo.appendingPathComponent(".build/test-fixtures/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct InventoryBackupTests {
    @Test func inspectionFindsActualNESLayoutAndFreeSpace() async throws {
        let inventory = try await DeviceInventoryService.inspect(shell: InventoryShell())
        #expect(inventory.profile.deviceID == "ABC123")
        #expect(inventory.syncBase == "/var/lib/hakchi/games/nes-usa")
        #expect(inventory.freeBytes == 307_200_000)
        #expect(inventory.canSync)
        #expect(inventory.installedCodes == ["CLV-H-AAAAA", "CLV-H-BBBBB"])
    }
    @Test(arguments: ["/media/usb/games/nes-usa/000", "/var/lib/hakchi/games/../../000", "/var/lib/hakchi/games/snes-usa/000"])
    func incompatibleStorageStaysInspectionOnly(path: String) async throws {
        let shell = InventoryShell(); await shell.set(active: path)
        #expect(try await DeviceInventoryService.inspect(shell: shell).canSync == false)
    }
    @Test func snesWritesRemainUnvalidated() async throws {
        let shell = InventoryShell(); await shell.set(system: "clv-snes-usa", active: "/var/lib/hakchi/games/snes-usa/000")
        #expect(try await DeviceInventoryService.inspect(shell: shell).canSync == false)
    }
    @Test func invalidCapacityCannotEnableWrites() async {
        let shell = InventoryShell(); await shell.set(capacity: "unavailable")
        await #expect(throws: (any Error).self) { try await DeviceInventoryService.inspect(shell: shell) }
    }
    @Test func verifiedBackupIsBinaryCompleteAndBoundToDevice() async throws {
        let shell = InventoryShell()
        let inventory = try await DeviceInventoryService.inspect(shell: shell)
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let backup = try await ConsoleBackupService.backup(inventory: inventory, shell: shell, destination: directory)
        let bytes = try Data(contentsOf: backup.directory.appendingPathComponent("console.tar"))
        #expect(bytes == (await shell.archive))
        #expect(FileManager.default.fileExists(atPath: backup.directory.appendingPathComponent("manifest.json").path))
        try ConsoleBackupService.verify(backup, for: inventory)
        #expect(throws: SyncPlanError.self) { try backup.manifest.verify(archive: bytes, for: ConsoleProfile(deviceID: "OTHER", systemCode: "nes-usa")) }
    }
    @Test func corruptBackupDoesNotProduceManifest() async throws {
        let shell = InventoryShell(); await shell.set(corrupt: true)
        let inventory = try await DeviceInventoryService.inspect(shell: shell)
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: (any Error).self) {
            try await ConsoleBackupService.backup(inventory: inventory, shell: shell, destination: directory)
        }
        let manifests = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        #expect(manifests.isEmpty)
    }
}

/// Runs the production export commands against real files, including a saves symlink.
actor LocalBackupShell: ConsoleShell {
    let root: URL
    init(root: URL) { self.root = root }
    func execute(_ command: String, timeout: Int) async throws -> SSHResult {
        var local = command
        for (remote, name) in [("var/squashfs/usr/share/games/nes/kachikachi", "stock"), ("var/lib/hakchi/games/nes-usa", "games"), ("var/saves", "saves"), ("var/lib/hakchi/config", "missing-config"), ("hakchi/config", "missing-hakchi")] {
            local = local.replacingOccurrences(of: "/" + remote, with: root.appendingPathComponent(name).path)
            local = local.replacingOccurrences(of: "'" + remote + "'", with: LaunchCommand.shellQuote(String(root.appendingPathComponent(name).path.dropFirst())))
        }
        local = local.replacingOccurrences(of: "sha256sum", with: "shasum -a 256")
        let output = root.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", local]; process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); try handle.close()
        let bytes = try Data(contentsOf: output); try FileManager.default.removeItem(at: output)
        return SSHResult(stdout: String(decoding: bytes, as: UTF8.self), stderr: "", stdoutData: bytes, exitCode: Int(process.terminationStatus))
    }
    func upload(data: Data, to remotePath: String, timeout: Int) async throws { Issue.record("Backup must be read only") }
    func uploadTar(data: Data, to directory: String, extraArgs: String, timeout: Int) async throws { Issue.record("Backup must be read only") }
}

extension InventoryBackupTests {
    @Test func backupIncludesSaveBytesBehindRealSymlink() async throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("stock"), withIntermediateDirectories: true)
        let saves = directory.appendingPathComponent("profiles/0")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("games"), withIntermediateDirectories: true)
        let bytes = Data([0, 255, 1, 0, 7])
        try bytes.write(to: saves.appendingPathComponent("save.dat"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("saves"), withDestinationURL: saves)
        let inventory = try await DeviceInventoryService.inspect(shell: InventoryShell())
        let backup = try await ConsoleBackupService.backup(inventory: inventory, shell: LocalBackupShell(root: directory), destination: directory.appendingPathComponent("exports"))
        let extraction = directory.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", backup.directory.appendingPathComponent("console.tar").path, "-C", extraction.path]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
        let contents = FileManager.default.enumerator(at: extraction, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "save.dat" } ?? []
        #expect(contents.count == 1)
        if let file = contents.first { #expect(try Data(contentsOf: file) == bytes) }
    }
}

extension InventoryBackupTests {
    @Test func backupIncludesOriginalGamesFromOwnConsole() async throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["stock", "games"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let original = Data([78, 69, 83, 26, 0, 255, 7])
        try original.write(to: directory.appendingPathComponent("stock/factory.nes"))
        let inventory = try await DeviceInventoryService.inspect(shell: InventoryShell())
        let backup = try await ConsoleBackupService.backup(inventory: inventory, shell: LocalBackupShell(root: directory), destination: directory.appendingPathComponent("exports"))
        #expect(backup.manifest.sourcePaths.contains { $0.hasSuffix("/stock") })
        let extraction = directory.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", backup.directory.appendingPathComponent("console.tar").path, "-C", extraction.path]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
        let files = FileManager.default.enumerator(at: extraction, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "factory.nes" } ?? []
        #expect(files.count == 1)
        if let file = files.first { #expect(try Data(contentsOf: file) == original) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("stock/factory.nes")) == original)
    }
}
