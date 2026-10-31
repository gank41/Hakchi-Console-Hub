import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryCleanupObservationTests {
    func frame(_ scope: SNESLibraryCleanupPlan, nonce: UUID, context: String, partial: Bool = false) -> Data {
        var tokens: [String] = []
        for (index, file) in scope.files.enumerated() {
            if partial && index % 2 == 0 { tokens.append("MISSING_FILE \(index)") }
            else { tokens.append("FILE \(index) \(file.byteCount) \(file.sha256) \(file.mode) \(file.modified) 1 \(index+100) \(file.identity.changed)") }
        }
        for (index, _) in scope.directories.enumerated() {
            tokens.append(partial && index % 2 == 0 ? "MISSING_DIR \(index)" : "DIR \(index) 448 1 \(index+2000)")
        }
        var rows: [String] = ["SWIFTHAKCHI_SNES_CLEANUP_PREVIEW_V1", "CHALLENGE=" + nonce.uuidString, "SCOPE=" + scope.reviewSHA256,
            "CONTEXT=" + context, "HWID=" + scope.hwid, "SELECTOR=" + scope.selection.selectorSHA256, "DEVICE=1", "FREE_BYTES=200000000",
            "FILES=" + String(scope.files.count), "DIRS=" + String(scope.directories.count)]
        rows += tokens
        rows += ["TOKENS_SHA=" + BackupManifest.digest(Data(tokens.joined(separator: "\n").utf8)), "END", ""]
        return Data(rows.joined(separator: "\n").utf8)
    }
    @Test(arguments: [false, true]) func previewBindsExactPathsAndFreshIdentitiesIncludingKnownMissingFiles(_ partial: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, live, backup, originals) = try await SNESLibraryCleanupPlanTests().fixture(root, changedROM: true)
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: live, backup: backup, originals: originals)
        let nonce = UUID(), raw = frame(scope, nonce: nonce, context: live.contextSHA256, partial: partial)
        let seen = try SNESLibraryCleanupObservation(raw, scope: scope, challenge: nonce, contextSHA256: live.contextSHA256)
        #expect(seen.files.count == scope.files.count && seen.directories.count == scope.directories.count)
        #expect(seen.files.compactMap { $0 }.count == (partial ? scope.files.count / 2 : scope.files.count))
        #expect(seen.freeBytes == 200000000)
        #expect(!seen.allGone)
    }
    @Test(arguments: ["scope", "nonce", "selector", "missing-row", "duplicate", "wrong-hash", "alias"])
    func damagedOrStalePreviewIsNotDeletionAuthority(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, live, backup, originals) = try await SNESLibraryCleanupPlanTests().fixture(root, changedROM: true)
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: live, backup: backup, originals: originals)
        let nonce = UUID(); var rows = String(decoding: frame(scope, nonce: nonce, context: live.contextSHA256), as: UTF8.self).components(separatedBy: "\n")
        if fault == "scope" { rows[2] = "SCOPE=" + String(repeating: "0", count: 64) }
        if fault == "selector" { rows[5] = "SELECTOR=" + String(repeating: "0", count: 64) }
        if fault == "missing-row" { rows.remove(at: 10) }
        if fault == "duplicate" { rows.insert(rows[10], at: 10) }
        if fault == "wrong-hash" { var fields = rows[10].components(separatedBy: " "); fields[3] = String(repeating: "0", count: 64); rows[10] = fields.joined(separator: " ") }
        if fault == "alias" { var fields = rows[11].components(separatedBy: " "); fields[7] = "100"; rows[11] = fields.joined(separator: " ") }
        if fault == "wrong-hash" || fault == "alias" {
            rows[rows.count-3] = "TOKENS_SHA=" + BackupManifest.digest(Data(rows[10..<rows.count-3].joined(separator: "\n").utf8))
        }
        let raw = Data(rows.joined(separator: "\n").utf8)
        #expect(throws: (any Error).self) { try SNESLibraryCleanupObservation(raw, scope: scope, challenge: fault == "nonce" ? UUID() : nonce, contextSHA256: live.contextSHA256) }
    }
}
