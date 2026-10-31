import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

struct LegacyStageVerificationTests {
    @Test func inventoryComparisonIdentifiesChangedExtractedFile() throws {
        let id = UUID()
        let sha = String(repeating: "a", count: 64)
        let expected: [LegacyMenuStageManifest.Entry] = [
            .init(relativePath: "000", kind: .directory, byteCount: 0, sha256: nil, linkTarget: nil),
            .init(relativePath: "000/game.nes", kind: .regular, byteCount: 4, sha256: sha, linkTarget: nil)
        ]
        let actual = "STAGE_INVENTORY:\(id.uuidString)\n000\tdirectory\t0\t\t\n000/game.nes\tregular\t4\t\(String(repeating: "b", count: 64))\t\nEND_STAGE_INVENTORY\n"
        let differences = try LegacyStageVerification.compareInventory(Data(actual.utf8), operationID: id, expected: expected)
        #expect(differences == ["000/game.nes: content hash differs"])
        let command = LegacyStageVerification.inventoryCommand(operationID: id)
        #expect(command.contains(LegacyStageVerification.stagePath(for: id)))
        #expect(!command.contains("tar -xf"))
        #expect(!command.contains("mv "))
    }
    @Test func inventoryComparisonReportsExtraEntryWithinBound() throws {
        let id = UUID()
        let expected: [LegacyMenuStageManifest.Entry] = [
            .init(relativePath: "000", kind: .directory, byteCount: 0,
                  sha256: nil, linkTarget: nil)
        ]
        let actual = "STAGE_INVENTORY:\(id.uuidString)\n000\tdirectory\t0\t\t\n001\tdirectory\t0\t\t\nEND_STAGE_INVENTORY\n"
        let differences = try LegacyStageVerification.compareInventory(
            Data(actual.utf8), operationID: id, expected: expected)
        #expect(differences == ["001: extra on NES"])
    }
    @Test func liveInventoryAllowsOnlyGeneratedRegularPageFonts() throws {
        let id = UUID(), hash = String(repeating: "a", count: 64)
        let expected: [LegacyMenuStageManifest.Entry] = [
            .init(relativePath: "000", kind: .directory, byteCount: 0,
                  sha256: nil, linkTarget: nil)
        ]
        let regular = "STAGE_INVENTORY:\(id.uuidString)\n000\tdirectory\t0\t\t\n000/title.fnt\tregular\t4\t\(hash)\t\nEND_STAGE_INVENTORY\n"
        #expect(try LegacyStageVerification.compareInventory(Data(regular.utf8),
            operationID: id, expected: expected, allowGeneratedPageFonts: true).isEmpty)
        let link = "STAGE_INVENTORY:\(id.uuidString)\n000\tdirectory\t0\t\t\n000/title.fnt\tsymbolicLink\t0\t\t/tmp/x\nEND_STAGE_INVENTORY\n"
        #expect(try LegacyStageVerification.compareInventory(Data(link.utf8),
            operationID: id, expected: expected, allowGeneratedPageFonts: true)
                == ["000/title.fnt: extra on NES"])
    }
    @Test func failedVerificationReportsConsoleStepWithoutTreatingItAsProtocolCorruption() throws {
        let id = UUID(), tree = String(repeating: "a", count: 64)
        let failure = SSHResult(stdout: "", stderr: "", stdoutData: Data(), exitCode: 69)
        do {
            try LegacyStageVerification.requireReceipt(failure, operationID: id, treeSHA256: tree)
            Issue.record("A failed console verification must not be accepted.")
        } catch {
            #expect(error.localizedDescription.contains("step 69"))
            #expect(error.localizedDescription.contains("active game menu was not changed"))
        }
    }
    @Test func extractionCommandIsBoundToInactiveSiblingAndExactHashes() throws {
        let id = UUID(), archive = String(repeating: "a", count: 64), tree = String(repeating: "b", count: 64)
        let link = LegacyMenuStageManifest.Entry(relativePath: "000/CLV-P-NAAEE/CLV-P-NAAEE.nes",
            kind: .symbolicLink, byteCount: 0, sha256: nil,
            linkTarget: "/var/squashfs/usr/share/games/nes/kachikachi/CLV-P-NAAEE/CLV-P-NAAEE.nes")
        let script = try LegacyStageVerification.command(operationID: id,
                    archiveSHA256: archive, archiveBytes: 8192, treeSHA256: tree,
                    stageBudgetBytes: 2 * 1024 * 1024, entries: [link])
        #expect(script.contains("/var/lib/hakchi/games/nes.swift-stage-\(id.uuidString)"))
        #expect(script.contains(LegacyStageTransfer.directory(for: id) + "/menu.tar"))
        #expect(script.contains(archive) && script.contains(tree))
        #expect(script.contains("tar -xf"))
        #expect(script.contains("ln -s"))
        #expect(script.contains(link.linkTarget!))
        #expect(script.contains("sha256sum"))
        #expect(script.contains("verified.marker"))
        #expect(script.contains("VERIFIED:\(id.uuidString):\(tree)"))
        #expect(!script.contains("mv \"$base/nes\""))
        #expect(script.utf8.count <= 65_536)
    }

    @Test func fullLibraryStageFitsVerificationAndDiagnosticBounds() throws {
        let id = UUID(), hash = String(repeating: "a", count: 64)
        var entries: [LegacyMenuStageManifest.Entry] = []
        for page in 0..<7 {
            entries.append(.init(relativePath: String(format: "%03d", page), kind: .directory,
                                 byteCount: 0, sha256: nil, linkTarget: nil))
        }
        for index in 0..<162 {
            let code = String(format: "CLV-H-%05d", index)
            let base = String(format: "%03d/", index / 25) + code
            entries.append(.init(relativePath: base, kind: .directory,
                                 byteCount: 0, sha256: nil, linkTarget: nil))
            for suffix in [".desktop", ".nes", ".png", "_small.png"] {
                entries.append(.init(relativePath: base + "/" + code + suffix, kind: .regular,
                                     byteCount: 1024, sha256: hash, linkTarget: nil))
            }
        }
        let script = try LegacyStageVerification.command(operationID: id,
            archiveSHA256: hash, archiveBytes: 8 * 1024 * 1024, treeSHA256: hash,
            stageBudgetBytes: 32 * 1024 * 1024, entries: entries)
        #expect(script.utf8.count <= 65_536)
        let rows = entries.map { entry in
            [entry.relativePath, entry.kind.rawValue, String(entry.byteCount),
             entry.sha256 ?? "", entry.linkTarget ?? ""].joined(separator: "\t")
        }
        let text = "STAGE_INVENTORY:\(id.uuidString)\n" + rows.joined(separator: "\n")
            + "\nEND_STAGE_INVENTORY\n"
        #expect(Data(text.utf8).count > 65_536)
        #expect(try LegacyStageVerification.compareInventory(Data(text.utf8),
            operationID: id, expected: entries).isEmpty)
    }

    @Test func invalidHashesAndReceiptsRefuse() throws {
        let id = UUID(), hash = String(repeating: "c", count: 64)
        #expect(throws: SyncPlanError.self) {
            try LegacyStageVerification.command(operationID: id,
                archiveSHA256: "bad", archiveBytes: 8192, treeSHA256: hash, stageBudgetBytes: 1024, entries: [])
        }
        let expected = "VERIFIED:\(id.uuidString):\(hash)\n"
        let good = SSHResult(stdout: expected, stderr: "", stdoutData: Data(expected.utf8), exitCode: 0)
        try LegacyStageVerification.requireReceipt(good, operationID: id, treeSHA256: hash)
        let warning = SSHResult(stdout: expected, stderr: "tar: metadata warning\n", stdoutData: Data(expected.utf8), exitCode: 0)
        try LegacyStageVerification.requireReceipt(warning, operationID: id, treeSHA256: hash)
        let bad = SSHResult(stdout: expected, stderr: "", stdoutData: Data(expected.utf8), exitCode: 1)
        #expect(throws: LegacyChangeError.self) {
            try LegacyStageVerification.requireReceipt(bad, operationID: id, treeSHA256: hash)
        }
    }
}
