import Foundation
import SwiftHakchiCore

extension SNESTemporaryMenuResult {
    private struct Manifest: Codable {
        let schemaVersion: Int, complete: Bool, firmwareWritten: Bool, firmwareRestoreEligible: Bool, persistentDataMounted: Bool
        let userGameplayConfirmed: Bool, stockReturnConfirmed: Bool
        let scope: String, phase: String, imageSHA256: String, nonce: String, binding: SNESRuntimeBinding
        let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice
        let challenges: [UUID], reportSHA256: [String]
    }
    func checkedExport(menu: PreparedSNESTemporaryMenu) throws -> (files: [String: Data], manifest: Data) {
        try menu.validateCurrent(); try validate(expected: menu.expectation)
        var files: [String: Data] = [:]
        for (index, data) in reports.enumerated() { files["report-\(index).txt"] = data }
        let m = Manifest(schemaVersion: 1, complete: true, firmwareWritten: false, firmwareRestoreEligible: false,
            persistentDataMounted: false, userGameplayConfirmed: false, stockReturnConfirmed: false,
            scope: "snes-temporary-menu-machine-result", phase: phase, imageSHA256: BackupManifest.digest(menu.image),
            nonce: menu.nonce, binding: menu.binding, before: before, after: after, challenges: challenges,
            reportSHA256: reports.map(BackupManifest.digest))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (files, try encoder.encode(m))
    }
    /// A receipt is accepted only with its actual parsed reports, never an edited success flag.
    static func loadStarted(directory url: URL, menu: PreparedSNESTemporaryMenu) throws -> Self {
        try menu.validateCurrent()
        let dir = try RestoreDirectory(url), prefix = "SNES-Temporary-Menu-Result-"
        guard dir.url.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESRuntimeBinding.failure() }
        let raw = try dir.read("manifest.json", maximum: 65536), m = try JSONDecoder().decode(Manifest.self, from: raw)
        guard m.schemaVersion == 1, m.complete, !m.firmwareWritten, !m.firmwareRestoreEligible, !m.persistentDataMounted,
              !m.userGameplayConfirmed, !m.stockReturnConfirmed, m.scope == "snes-temporary-menu-machine-result", m.phase == "started",
              m.imageSHA256 == BackupManifest.digest(menu.image), m.nonce == menu.nonce, m.binding == menu.binding,
              m.challenges.count == 2, m.reportSHA256.count == 2 else { throw SNESRuntimeBinding.failure() }
        let reports = try (0..<2).map { try dir.read("report-\($0).txt", maximum: 65536) }
        guard reports.map(BackupManifest.digest) == m.reportSHA256 else { throw SNESRuntimeBinding.failure() }
        let result = Self(before: m.before, after: m.after, challenges: m.challenges, reports: reports, phase: m.phase)
        let export = try result.checkedExport(menu: menu)
        guard let saved = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let actual = try JSONSerialization.jsonObject(with: export.manifest) as? NSDictionary,
              actual.isEqual(to: saved) else { throw SNESRuntimeBinding.failure() }
        try dir.check(); return result
    }
}
extension SNESTemporaryMenuFailure {
    func checkedExport(menu: PreparedSNESTemporaryMenu) throws -> (files: [String: Data], manifest: Data) {
        guard report.count <= 65536, diagnostics.count <= 65536, capturedReports.count <= 2, capturedReports.allSatisfy({ $0.count <= 65536 }),
              stage.utf8.count <= 64, stage.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }) else { throw SNESRuntimeBinding.failure() }
        let json: [String: Any] = ["schemaVersion": 1, "complete": false, "firmwareWritten": false,
            "firmwareRestoreEligible": false, "persistentDataMounted": false, "scope": "snes-temporary-menu-diagnostic",
            "stage": stage, "candidateSHA256": BackupManifest.digest(menu.image), "reportSHA256": BackupManifest.digest(report),
            "diagnosticSHA256": BackupManifest.digest(diagnostics), "reportBytes": report.count, "diagnosticBytes": diagnostics.count, "capturedReportSHA256": capturedReports.map(BackupManifest.digest)]
        var files: [String: Data] = [:]
        for (index, data) in capturedReports.enumerated() where !data.isEmpty { files["report-\(index).txt"] = data }
        if !report.isEmpty { files["partial-report.txt"] = report }
        if !diagnostics.isEmpty { files["diagnostic.txt"] = diagnostics }
        return (files,
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
    }
}
