import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

actor ImportShell: ConsoleShell {
    let archive: Data
    let digest: String
    init(escaping: Bool = false, corrupt: Bool = false) {
        var tar = TarWriter()
        tar.addFile(name: escaping ? "CLV-H-AAAAA/../../escape.nes" : "CLV-H-AAAAA/a.nes", contents: Data([0, 1, 255, 0]))
        archive = tar.finalize()
        digest = corrupt ? String(repeating: "0", count: 64) : BackupManifest.digest(archive)
    }
    func execute(_ command: String, timeout: Int) async throws -> SSHResult {
        let text: String
        if command.contains("sha256sum") { text = digest }
        else if command.hasPrefix("tar -c ") { return SSHResult(stdout: "", stderr: "", stdoutData: archive, exitCode: 0) }
        else { throw SSHError.commandFailed(command: command, exitCode: 127, stderr: "unexpected command") }
        return SSHResult(stdout: text, stderr: "", stdoutData: Data(text.utf8), exitCode: 0)
    }
    func upload(data: Data, to remotePath: String, timeout: Int) async throws { Issue.record("Import must not upload") }
    func uploadTar(data: Data, to directory: String, extraArgs: String, timeout: Int) async throws { Issue.record("Import must not write to console") }
}

struct ConsoleImportTests {
    @Test func importVerifiesBinaryBytesBeforeInstallingLocalCopy() async throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await ConsoleGameImporter.importGame(code: "CLV-H-AAAAA", storage: "/var/lib/hakchi/games/nes-usa/.storage", desktop: Data("Name=Example\nCode=CLV-H-AAAAA".utf8), destination: directory, shell: ImportShell())
        #expect(try Data(contentsOf: url.appendingPathComponent("a.nes")) == Data([0, 1, 255, 0]))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("CLV-H-AAAAA.desktop").path))
    }
    @Test(arguments: [(true, false), (false, true)])
    func unsafeOrCorruptImportsNeverEnterLibrary(sample: (Bool, Bool)) async throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: (any Error).self) {
            try await ConsoleGameImporter.importGame(code: "CLV-H-AAAAA", storage: "/var/lib/hakchi/games/nes-usa/.storage", desktop: Data(), destination: directory, shell: ImportShell(escaping: sample.0, corrupt: sample.1))
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("CLV-H-AAAAA").path) == false)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.nes").path) == false)
    }
}

actor LibraryListShell: ConsoleShell {
    func execute(_ command: String, timeout: Int) async throws -> SSHResult {
        let text: String
        let exit: Int
        if command.hasPrefix("ls -1 ") { text = "CLV-P-NAAAE\nCLV-P-NBBBE\nCLV-S-00001"; exit = 0 }
        else if command.hasPrefix("find ") {
            let code = command.contains("CLV-H-AAAAA") ? "CLV-H-AAAAA" : "CLV-H-BBBBB"
            text = "/var/lib/hakchi/games/nes-usa/001/\(code)/\(code).desktop"; exit = 0
        } else if command.contains("/.storage/") { text = ""; exit = 1 }
        else if command.hasPrefix("cat ") {
            let code = command.contains("CLV-P-NAAAE") ? "CLV-P-NAAAE" : (command.contains("CLV-P-NBBBE") ? "CLV-P-NBBBE" : (command.contains("CLV-H-AAAAA") ? "CLV-H-AAAAA" : "CLV-H-BBBBB"))
            text = "Name=\(code)\nCode=\(code)\nExec=/bin/play /var/games/\(code)/a.nes"; exit = 0
        } else { throw SSHError.commandFailed(command: command, exitCode: 127, stderr: "unexpected command") }
        return SSHResult(stdout: text, stderr: "", stdoutData: Data(text.utf8), exitCode: exit)
    }
    func upload(data: Data, to remotePath: String, timeout: Int) async throws { Issue.record("Inventory must not upload") }
    func uploadTar(data: Data, to directory: String, extraArgs: String, timeout: Int) async throws { Issue.record("Inventory must not upload") }
}

struct ConsoleLibraryTests {
    @Test func findsAllInstalledGamesAndSkipsNavigation() async throws {
        let inventory = try await DeviceInventoryService.inspect(shell: InventoryShell())
        let games = try await ConsoleLibraryService.read(inventory: inventory, shell: LibraryListShell())
        #expect(Set(games.map(\.code)) == ["CLV-P-NAAAE", "CLV-P-NBBBE", "CLV-H-AAAAA", "CLV-H-BBBBB"])
        #expect(games.filter(\.isStock).count == 2)
    }
}

extension LibraryTests {
    @Test func firstConnectionKeepsWindowsHiddenStockHidden() async throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let config = AppConfig.shared; let oldPath = config.workspacePath
        config.workspacePath = directory.path; defer { config.workspacePath = oldPath }
        let inventory = try await DeviceInventoryService.inspect(shell: InventoryShell())
        let remote = try await ConsoleLibraryService.read(inventory: inventory, shell: LibraryListShell())
        let manager = GameManagerService()
        manager.mergeConsoleGames(remote, installedCodes: inventory.installedCodes, deviceID: "ABC123", consoleType: .nes)
        #expect(manager.games.first { $0.code == "CLV-P-NAAAE" }?.isSelected == true)
        #expect(manager.games.first { $0.code == "CLV-P-NBBBE" }?.isSelected == false)
    }
}
