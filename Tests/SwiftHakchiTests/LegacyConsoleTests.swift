import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore


actor LegacyConsoleFixture: LegacyRequestExecuting {
    var corrupt: Bool
    var mismatchingDigests: Int
    let failBackupRead: Bool
    private(set) var backupReads = 0
    var metadata: Data
    let archive: Data
    init(corrupt: Bool = false, escaping: Bool = false, auxiliary: Bool = false,
         omittingCustom: Bool = false, pageStock: Bool = false, mismatchingDigests: Int = 0,
         failBackupRead: Bool = false) {
        self.corrupt = corrupt
        self.mismatchingDigests = mismatchingDigests
        self.failBackupRead = failBackupRead
        var tar = TarWriter()
        for (code, prefix) in [("CLV-P-AAAAA", "var/squashfs/usr/share/games/nes/kachikachi"), ("CLV-P-BBBBB", "var/squashfs/usr/share/games/nes/kachikachi"), ("CLV-H-CCCCC", "var/lib/hakchi/games/nes/000")] {
            if omittingCustom && code == "CLV-H-CCCCC" { continue }
            let name = escaping ? "../escape.desktop" : prefix + "/" + code + "/" + code + ".desktop"
            tar.addFile(name: name, contents: Data("Name=\(code)\nCode=\(code)\nExec=/bin/play /var/games/\(code)/a.nes\n".utf8))
        }
        if pageStock {
            for code in ["CLV-P-AAAAA", "CLV-P-BBBBB"] {
                let path = "var/lib/hakchi/games/nes/000/\(code)/\(code).desktop"
                let content = "Name=Working \(code)\nCode=\(code)\nExec=/bin/clover-kachikachi-wr \(LegacyConsoleReport.factoryRoot)/\(code)/\(code).nes\n"
                tar.addFile(name: path, contents: Data(content.utf8))
            }
        }
        if auxiliary { tar.addFile(name: "var/squashfs/usr/share/games/nes/kachikachi/PRODUCTION-TESTS/PRODUCTION-TESTS.desktop", contents: Data("Name=Factory diagnostics".utf8)) }
        metadata = tar.finalize()
        var backup = TarWriter()
        for name in ["var/lib/hakchi/marker", "var/lib/clover/profiles/0/save.dat", "var/squashfs/usr/share/games/nes/kachikachi/CLV-P-AAAAA/a.nes", "var/squashfs/usr/share/games/nes/kachikachi/CLV-P-BBBBB/b.nes"] { backup.addFile(name: name, contents: Data([0, 255, 2, 0])) }
        archive = backup.finalize()
    }
    func setMetadata(_ data: Data) { metadata = data }
    func execute(_ request: LegacyReadRequest, timeoutMilliseconds: Int) -> SSHResult {
        let data: Data
        switch request {
        case .consoleIdentity: data = Data("SWIFTHAKCHI_CONSOLE_ID_V1\nBOARD=dp-nes\nREGION=EUR_USA\nEND\n".utf8)
        case .report: data = Data(legacyReportFixture.utf8)
        case .chipID, .storageReport, .snesRAMProbeReport, .snesTemporaryMenuReport, .snesTemporaryMenuDiagnostics, .snesOriginalMenuReport, .snesOriginalMenuDiagnostics, .snesAlienTrialReport: data = Data()
        case .metadata: data = metadata
        case .backup:
            backupReads += 1
            if failBackupRead { return SSHResult(stdout: "", stderr: "read failed", stdoutData: Data(), exitCode: 1) }
            data = archive
        case .backupDigest:
            let mismatch = corrupt || mismatchingDigests > 0
            if mismatchingDigests > 0 { mismatchingDigests -= 1 }
            data = Data((mismatch ? String(repeating: "0", count: 64) : BackupManifest.digest(archive)).utf8)
        }
        return SSHResult(stdout: String(decoding: data, as: UTF8.self), stderr: "", stdoutData: data, exitCode: 0)
    }
}

struct LegacyConsoleTests {
    @Test func oldFirmwareReportHasNoInventedWritableIdentity() throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        #expect(report.activePage == "/var/lib/hakchi/games/nes/000")
        #expect(report.freeBytes == 326700 * 1024)
        #expect(report.bootVersion == "1.0.1")
        #expect(report.visibleCodes == ["CLV-P-AAAAA", "CLV-H-CCCCC"])
        #expect(!report.canSync && !report.identityVerified)
    }
    @Test(arguments: ["/var/lib/hakchi/games/nes/000", "/var/lib/clover/profiles/0", "326700", "__END__"])
    func malformedOrUnsupportedReportsAreRejected(field: String) {
        let changed = legacyReportFixture.replacingOccurrences(of: field, with: "unsupported")
        #expect(throws: (any Error).self) { try LegacyConsoleReport.parse(Data(changed.utf8)) }
    }
    @Test func readsStockAndLegacyCustomMetadataAndPreservesHiddenStock() async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        let games = try await LegacyConsoleService.games(client: LegacyConsoleFixture(), report: report)
        #expect(Set(games.map(\.code)) == ["CLV-P-AAAAA", "CLV-P-BBBBB", "CLV-H-CCCCC"])
        #expect(games.first { $0.code == "CLV-P-BBBBB" }?.isSelected == false)
        #expect(games.first { $0.code == "CLV-H-CCCCC" }?.isSelected == true)
    }
    @Test func prefersPreservedWorkingPageLaunchersForStockGames() async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        let games = try await LegacyConsoleService.games(client: LegacyConsoleFixture(pageStock: true), report: report)
        #expect(games.first { $0.code == "CLV-P-AAAAA" }?.name == "Working CLV-P-AAAAA")
        #expect(games.filter(\.isStock).allSatisfy { $0.commandLine.hasPrefix("/bin/clover-kachikachi-wr ") })
    }
    @Test func unsafeMetadataArchiveNeverBecomesLibraryEntries() async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        await #expect(throws: (any Error).self) { try await LegacyConsoleService.games(client: LegacyConsoleFixture(escaping: true), report: report) }
    }
    @Test func verifiedLegacyBackupIsExplicitlyIneligibleForAutomaticRestore() async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let backup = try await LegacyConsoleService.backup(client: LegacyConsoleFixture(), report: report, destination: directory)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: backup.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(object["eligibleForAutomaticRestore"] as? Bool == false)
        #expect(object["deviceIdentityVerified"] as? Bool == false)
        #expect(object["remoteArchiveHashMatched"] as? Bool == true)
    }
    @Test func changedBackupBytesNeverProduceVerifiedManifest() async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = LegacyConsoleFixture(corrupt: true)
        await #expect(throws: (any Error).self) { try await LegacyConsoleService.backup(client: fixture, report: report, destination: directory) }
        #expect(await fixture.backupReads == 2)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL } ?? []
        #expect(!files.contains { $0.lastPathComponent == "manifest.json" })
        #expect(files.contains { $0.lastPathComponent == "console.tar.partial" })
    }
    @Test func changingMenuSettingsGetOneFreshReadBeforeBackupIsAccepted() async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = LegacyConsoleFixture(mismatchingDigests: 1)
        let backup = try await LegacyConsoleService.backup(client: fixture, report: report, destination: directory)
        #expect(await fixture.backupReads == 2)
        let manifest = try #require(JSONSerialization.jsonObject(with:
            Data(contentsOf: backup.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["sha256"] as? String == BackupManifest.digest(try Data(contentsOf: backup.appendingPathComponent("console.tar"))))
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL } ?? []
        #expect(files.filter { $0.lastPathComponent == "manifest.json" }.count == 1)
        #expect(files.filter { $0.lastPathComponent == "console.tar.partial" }.count == 1)
    }
    @Test func failedUSBBackupReadIsNeverAutomaticallyRepeated() async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = LegacyConsoleFixture(failBackupRead: true)
        await #expect(throws: (any Error).self) {
            try await LegacyConsoleService.backup(client: fixture, report: report, destination: directory)
        }
        #expect(await fixture.backupReads == 1)
    }
}


extension LegacyConsoleTests {
    @Test func auxiliaryFactoryLauncherIsNotTreatedAsMalformedGame() async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        let games = try await LegacyConsoleService.games(client: LegacyConsoleFixture(auxiliary: true), report: report)
        #expect(games.count == 3)
        #expect(games.allSatisfy { $0.code.hasPrefix("CLV-") })
    }
}


extension LegacyConsoleTests {
    @Test func missingReportedCustomMetadataCannotLookComplete() async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        await #expect(throws: (any Error).self) {
            try await LegacyConsoleService.games(client: LegacyConsoleFixture(omittingCustom: true), report: report)
        }
    }
    @Test(arguments: ["00000002000", "77777777777"], [UInt8(120), 103, 88])
    func truncatedExtendedTarPayloadFailsWithoutTrapping(declaredSize: String, headerType: UInt8) async throws {
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        let fixture = LegacyConsoleFixture()
        var writer = TarWriter()
        writer.addFile(name: "PaxHeader", contents: Data())
        var bytes = Array(writer.finalize().prefix(512))
        bytes.replaceSubrange(124..<136, with: Array((declaredSize + "\0").utf8))
        bytes[156] = headerType
        bytes.replaceSubrange(148..<156, with: Array(repeating: UInt8(ascii: " "), count: 8))
        let sum = bytes.reduce(0) { $0 + Int($1) }
        bytes.replaceSubrange(148..<156, with: Array(String(format: "%06o", sum).utf8) + [0, 32])
        await fixture.setMetadata(Data(bytes))
        await #expect(throws: (any Error).self) {
            try await LegacyConsoleService.games(client: fixture, report: report)
        }
    }
}
