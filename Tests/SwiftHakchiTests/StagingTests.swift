import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

actor ArchiveShell: ConsoleShell {
    var files: [String: Data] = [:]
    func file(_ path: String) -> Data? { files[path] }
    func execute(_ command: String, timeout: Int) async throws -> SSHResult {
        SSHResult(stdout: "", stderr: "", stdoutData: Data(), exitCode: 0)
    }
    func upload(data: Data, to remotePath: String, timeout: Int) async throws { files[remotePath] = data }
    func uploadTar(data: Data, to directory: String, extraArgs: String, timeout: Int) async throws {
        var offset = 0
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<offset + 512)
            if header.allSatisfy({ $0 == 0 }) { break }
            let name = String(decoding: header.prefix(100).prefix { $0 != 0 }, as: UTF8.self)
            let sizeText = String(decoding: header[124..<136].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let size = Int(sizeText, radix: 8) ?? 0
            if header[156] != 53 { files[directory + "/" + name] = data.subdata(in: offset + 512..<offset + 512 + size) }
            offset += 512 + ((size + 511) / 512) * 512
        }
    }
}

struct StagingTests {
    @Test func customCoreCommandSurvivesStagingAndPointsAtFinalPath() async throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data("synthetic ROM".utf8).write(to: directory.appendingPathComponent("a.nes"))
        let desktop = Data("[Desktop Entry]\nName=Example\nExec=/bin/retroarch-clover /var/games/CLV-H-AAAAA/a.nes --core fceumm --verbose\nPath=/var/saves/CLV-H-AAAAA\n[X-CLOVER Game]\nCode=CLV-H-AAAAA\n".utf8)
        let input = SyncGameInput(code: "CLV-H-AAAAA", name: "Example", isStock: false, localDirectory: directory, romFilename: "a.nes", desktopData: desktop, selected: true, byteCount: 100)
        let plan = try SyncPlanner.makePlan(inputs: [input], installedCodes: [], profile: .init(deviceID: "ABC123", systemCode: "nes-usa"), freeBytes: 20_000_000, reserveBytes: 10_000_000)
        let shell = ArchiveShell()
        let service = GameSyncService(shell: shell, consoleType: .nes)
        try await service.prepareStage(plan: plan, stagingBase: "/stage", finalBase: "/var/lib/hakchi/games/nes-usa")
        let data = try #require(await shell.file("/stage/000/CLV-H-AAAAA/CLV-H-AAAAA.desktop"))
        let command = DesktopFile(data: data).exec
        #expect(command == "/bin/retroarch-clover '/var/lib/hakchi/games/nes-usa/.storage/CLV-H-AAAAA/a.nes' --core fceumm --verbose")
        #expect(await shell.file("/stage/.storage/CLV-H-AAAAA/a.nes") == Data("synthetic ROM".utf8))
        let hashes = try #require(await shell.file("/stage/.sync-checksums"))
        #expect(String(decoding: hashes, as: UTF8.self).contains(".storage/CLV-H-AAAAA/a.nes"))
    }
}
