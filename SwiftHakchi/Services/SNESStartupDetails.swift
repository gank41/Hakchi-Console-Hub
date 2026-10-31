import Foundation
import SwiftHakchiCore

/// Fixed, bounded data captured before the menu is released. Grants no startup eligibility.
struct SNESStartupDetails {
    static let paths: [(String, Int)] = [
        ("/proc/cmdline", 1024), ("/sys/class/graphics/fb0/name", 128),
        ("/sys/class/graphics/fb0/virtual_size", 128), ("/sys/class/graphics/fb0/bits_per_pixel", 128),
        ("/usr/share/applications/clover-mcp.desktop", 4096),
        ("/usr/share/applications/clover-ui.menu.desktop", 2048),
        ("/usr/share/applications/clover-ui.test.desktop", 2048),
        ("/usr/share/applications/clover-reset.factory.desktop", 2048),
        ("/usr/share/applications/clover-reset.menu.desktop", 2048),
        ("/etc/clover/LANGUAGE", 128), ("/proc/iomem", 8192)]
    static func optional(_ path: String) -> Bool {
        path.hasPrefix("/sys/") || path == "/etc/clover/LANGUAGE" ||
        (path.hasPrefix("/usr/") && path != "/usr/share/applications/clover-mcp.desktop")
    }
    let raw: Data
    init(_ raw: Data) throws {
        guard raw.count <= 24576 else { throw SNESRuntimeBinding.failure() }
        let bytes = Array(raw); var cursor = 0
        func line() throws -> String {
            guard cursor < bytes.count, let end = bytes[cursor..<min(bytes.count, cursor+512)].firstIndex(of: 10),
                  bytes[cursor..<end].allSatisfy({ (32...126).contains($0) }) else { throw SNESRuntimeBinding.failure() }
            let result = String(decoding: bytes[cursor..<end], as: UTF8.self); cursor = end+1; return result
        }
        guard try line() == "SNES_STARTUP_DETAILS_BEGIN" else { throw SNESRuntimeBinding.failure() }
        for (path, maximum) in Self.paths {
            let parts = try line().components(separatedBy: " ")
            guard parts.count == 5, parts[0] == "FILE", parts[1] == path,
                  let count = Int(parts[3]), String(count) == parts[3], (0...maximum).contains(count), count < bytes.count-cursor else { throw SNESRuntimeBinding.failure() }
            if parts[2] == "A" {
                guard Self.optional(path), count == 0, parts[4] == "-" else { throw SNESRuntimeBinding.failure() }
            } else {
                guard parts[2] == "F", count > 0,
                      BackupManifest.digest(Data(bytes[cursor..<cursor+count])) == parts[4] else { throw SNESRuntimeBinding.failure() }
            }
            cursor += count
            guard bytes[cursor] == 10 else { throw SNESRuntimeBinding.failure() }; cursor += 1
        }
        guard try line() == "SNES_STARTUP_DETAILS_END", cursor == bytes.count else { throw SNESRuntimeBinding.failure() }
        self.raw = raw
    }
    static func fromBaseline(_ baseline: Data) throws -> Self {
        let marker = Data("SNES_STARTUP_DETAILS_BEGIN\n".utf8), suffix = Data("SNES_PRE_MENU_END\n".utf8)
        guard let start = baseline.range(of: marker), baseline.suffix(suffix.count) == suffix else { throw SNESRuntimeBinding.failure() }
        return try Self(Data(baseline[start.lowerBound..<baseline.count-suffix.count]))
    }
}

struct SNESStartupCapture: Sendable {
    let checkpoint: SNESOriginalMenuCheckpoint, checkpointDirectory: URL, diagnostics: Data
    func checkedExport(menu: PreparedSNESOriginalMenu) throws -> (files: [String: Data], manifest: Data) {
        try menu.validateCurrent()
        let saved = try SNESOriginalMenuCheckpoint.load(directory: checkpointDirectory, menu: menu)
        guard saved.report == checkpoint.report, saved.challenge == checkpoint.challenge,
              saved.before == checkpoint.before, saved.after == checkpoint.after else { throw SNESRuntimeBinding.failure() }
        let report = try SNESOriginalMenuReport(checkpoint.report, expected: menu.expectation, challenge: checkpoint.challenge, state: .preMenu)
        let details = try SNESStartupDetails.fromBaseline(report.baseline)
        _ = try SNESOriginalMenuDiagnostics(diagnostics, nonce: menu.nonce)
        let receipt = try RestoreDirectory(checkpointDirectory).read("manifest.json", maximum: 65536)
        let manifest: [String: Any] = ["schemaVersion": 1, "scope": "snes-startup-details", "complete": true,
            "menuLaunched": false, "firmwareWritten": false, "firmwareRestoreEligible": false,
            "imageSHA256": BackupManifest.digest(menu.image), "nonce": menu.nonce,
            "checkpointPath": checkpointDirectory.path, "checkpointSHA256": BackupManifest.digest(receipt),
            "detailsSHA256": BackupManifest.digest(details.raw), "diagnosticSHA256": BackupManifest.digest(diagnostics)]
        return (["startup-details.bin": details.raw, "diagnostic.log": diagnostics],
                try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]))
    }
}
