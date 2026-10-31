import Foundation
import Testing
import SWCompression
@testable import SwiftHakchi
@testable import SwiftHakchiCore

struct RecoveryPreflightTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func realRecoveredStockAndPackagedPayloadsPassOfflineInspection() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"])
        let report = await RecoveryPreflightService().inspect(backups: URL(fileURLWithPath: path))
        #expect(report.kernel.status == .verified)
        #expect(report.kernel.detail.contains("83efe33290867ec6e6b5c5a18e21f8cfe6f97b079c2e3c5039c628e729755888"))
        #expect(report.payload.status == .verified)
        #expect(report.warnings.isEmpty)
        #expect(!report.canReset && report.scopes.allSatisfy { !$0.canExecute })
        let source = try #require(report.kernel.path)
        #expect(BackupManifest.digest(try Data(contentsOf: source)) == "83efe33290867ec6e6b5c5a18e21f8cfe6f97b079c2e3c5039c628e729755888")
    }

    static var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SwiftHakchi/Resources")
    }
    @Test func recognizesOnlyExactBundledPayloadsWithoutChangingBytes() throws {
        let fes = try Data(contentsOf: Self.resources.appendingPathComponent("fes1.bin"))
        let hmod = try Data(contentsOf: Self.resources.appendingPathComponent("hakchi.hmod"))
        let base = try Data(contentsOf: Self.resources.appendingPathComponent("basehmods.tar"))
        let evidence = try RecoveryPayloadValidator.validate(fes1: fes, hmod: hmod, baseHmods: base)
        #expect(evidence.bootImageSHA256 == "9e921c326be65aa4a3100270e86fdb15fe4b8563d586941b9f6c640eef064e4c")
        #expect(evidence.ubootSHA256 == "5cfacb297b962a388d947e3be553692bb1e9df9edc1125ca5a769166d3a89564")
        #expect(try Data(contentsOf: Self.resources.appendingPathComponent("hakchi.hmod")) == hmod)
        var altered = hmod; altered[0] ^= 1
        #expect(throws: (any Error).self) { try RecoveryPayloadValidator.validate(fes1: fes, hmod: altered, baseHmods: base) }
        #expect(throws: (any Error).self) { try RecoveryPayloadValidator.validate(fes1: Data(), hmod: hmod, baseHmods: base) }
        #expect(throws: (any Error).self) { try RecoveryPayloadValidator.validate(fes1: fes, hmod: hmod, baseHmods: Data()) }
    }
    @Test func duplicateOrLinkedArchiveTargetsAreRefused() throws {
        let ordinary = TarEntry(info: TarEntryInfo(name: "boot/boot.img", type: .regular), data: Data([1]))
        let alias = TarEntry(info: TarEntryInfo(name: "./boot/boot.img", type: .regular), data: Data([1]))
        let linked = TarEntry(info: TarEntryInfo(name: "boot/boot.img", type: .symbolicLink), data: nil)
        #expect(try RecoveryPayloadValidator.member("boot/boot.img", entries: [ordinary]) == Data([1]))
        for entries in [[ordinary, alias], [linked], []] {
            #expect(throws: (any Error).self) { try RecoveryPayloadValidator.member("boot/boot.img", entries: entries) }
        }
    }
    @Test func bootCommandMustBeUniqueBoundedAndLargeEnough() throws {
        #expect(try RecoveryPayloadValidator.bootCommandRange(in: Data("prefix bootcmd=long-enough-command\0tail".utf8)).count == 19)
        for value in ["bootcmd=short\0", "bootcmd=unterminated", "bootcmd=long-enough-command\0bootcmd=another-command\0", "no command"] {
            #expect(throws: (any Error).self) { try RecoveryPayloadValidator.bootCommandRange(in: Data(value.utf8)) }
        }
    }
    @Test func missingMaterialsAndUnknownStockNeverEnableReset() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = RecoveryPreflightService(payloadEvidence: { throw RecoveryImageError.invalid("Fixture payload unavailable") })
        let missing = await service.inspect(backups: root.appendingPathComponent("missing"))
        #expect(missing.kernel.status == .missing && missing.payload.status == .failed)
        let candidate = root.appendingPathComponent("RecoveryMaterial-test")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        var bytes = Data("ANDROID!".utf8); bytes.append(Data(count: 70000))
        let file = candidate.appendingPathComponent("kernel-stock-NES.img")
        try bytes.write(to: file)
        let report = await service.inspect(backups: root)
        #expect(report.kernel.status == .failed)
        #expect(!report.canReset && report.scopes.count == 5)
        #expect(report.scopes.allSatisfy { !$0.canExecute })
        #expect(try Data(contentsOf: file) == bytes)
    }
    @Test func symbolicLinksAndExcessiveCandidatesAreRefused() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = RecoveryPreflightService(payloadEvidence: { throw RecoveryImageError.invalid("Fixture payload unavailable") })
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedRoot = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        #expect(await service.inspect(backups: linkedRoot).kernel.status == .failed)
        let backups = root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let candidate = backups.appendingPathComponent("RecoveryMaterial-linked")
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: outside)
        #expect(await service.inspect(backups: backups).kernel.status == .failed)
        try FileManager.default.removeItem(at: candidate)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let source = outside.appendingPathComponent("source.img"); try Data([1,2,3]).write(to: source)
        try FileManager.default.createSymbolicLink(at: candidate.appendingPathComponent("kernel-stock-NES.img"), withDestinationURL: source)
        #expect(await service.inspect(backups: backups).kernel.status == .failed)
        #expect(try Data(contentsOf: source) == Data([1,2,3]))
        for i in 0..<65 { try FileManager.default.createDirectory(at: backups.appendingPathComponent("RecoveryMaterial-\(i)"), withIntermediateDirectories: true) }
        let report = await service.inspect(backups: backups)
        #expect(report.kernel.status == .failed)
        #expect(report.kernel.detail.contains("64"))
    }
}
