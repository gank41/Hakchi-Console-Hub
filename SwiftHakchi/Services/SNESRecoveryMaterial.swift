import Foundation
import SwiftHakchiCore

/// Planning bounds corroborated by the retained raw-tool source. Not write authorization.
struct SNESBoot2Bounds: Sendable {
    let activeStart = 0x600000, alternateStart = 0xd00000, unit = 0x20000
    init(partitions: Data) throws {
        guard let text = String(data: partitions, encoding: .ascii) else { throw SNESOfflineSource.failure() }
        try StockRestorePartitions.validate(text)
        let token = text.split(separator: "\n")[1].split(separator: " ")[0]
        guard token == "mbr::32768" else { throw SNESOfflineSource.failure() }
    }
    func checkedExtent(byteCount: Int) throws -> Range<Int> {
        let maximum = alternateStart - activeStart
        guard byteCount > 0, byteCount <= maximum else { throw SNESOfflineSource.failure() }
        let rounded = ((byteCount + unit - 1) / unit) * unit
        guard rounded <= maximum else { throw SNESOfflineSource.failure() }
        return activeStart..<(activeStart + rounded)
    }
}

/// A self-contained, per-console Mac backup. Deliberately has no write/boot API.
struct SNESRecoveryMaterial: Sendable {
    private let source: SNESOfflineSource
    private let isPackage: Bool
    private let files: [String: Data]
    private let sourceManifest: Data
    let bounds: SNESBoot2Bounds
    var expectedHWID: String { source.expectedHWID.lowercased() }
    var stock: Data { source.stock }
    var partitions: Data { files["partitions.txt"]! }
    static func load(setup: URL) throws -> Self { try Self(source: SNESOfflineSource.load(snapshot: setup)) }
    private init(source: SNESOfflineSource, isPackage: Bool = false) throws {
        try source.revalidate()
        let directory = try RestoreDirectory(source.directoryURL)
        let manifest = try directory.read("manifest.json", maximum: 65536)
        guard let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let capture = object["capture"] as? [String: Any], let kernel = capture["kernel"] as? [String: Any],
              let backup = kernel["backup"] as? [String: Any], let backupStatus = backup["status"] as? String else { throw SNESOfflineSource.failure() }
        var files = ["active-boot2.img": source.stock,
                     "boot1.bin": try directory.read("boot1.bin", maximum: RecoveryBoot1Read.maximumSize),
                     "partitions.txt": try directory.read("partitions.txt", maximum: 16384),
                     "data-header.bin": try directory.read("data-header.bin", maximum: 2048)]
        if backupStatus != "unavailable" { files["backup-boot2.img"] = try directory.read("backup-boot2.img") }
        let bounds = try SNESBoot2Bounds(partitions: files["partitions.txt"]!)
        _ = try bounds.checkedExtent(byteCount: source.stock.count)
        guard files["boot1.bin"]!.count <= bounds.activeStart - 0x100000 else { throw SNESOfflineSource.failure() }
        self.isPackage = isPackage
        self.source = source; self.files = files; sourceManifest = manifest; self.bounds = bounds
        try source.revalidate(); try directory.check()
    }
    func requireHardwareID(_ hwid: String) throws {
        guard hwid.lowercased() == expectedHWID else {
            throw RecoveryProbeError.refused("This backup belongs to a different console. Choose this console’s own recovery backup.")
        }
    }
    func revalidate() throws {
        try source.revalidate()
        if isPackage { _ = try Self.loadPackage(directory: source.directoryURL) }
    }
    private struct Choice: Codable {
        let choice: ConsoleRestoreChoice, title: String, explanation: String
        let effects: ConsoleRestoreChoice.Effects
        let executionAvailable: Bool
    }
    private struct Review: Codable {
        let schemaVersion: Int
        let scope: String
        let expectedHWID: String, originalImageSHA256: String
        let originalImageBytes: Int, activeStart: Int, activeExtentEnd: Int, alternateStart: Int
        let geometryWriteAuthorized: Bool, firmwareRestoreEligible: Bool
        let choices: [Choice]
    }
    private func review() throws -> Data {
        let review = Review(schemaVersion: 1, scope: "snes-recovery-review", expectedHWID: expectedHWID, originalImageSHA256: BackupManifest.digest(stock),
            originalImageBytes: stock.count, activeStart: bounds.activeStart,
            activeExtentEnd: try bounds.checkedExtent(byteCount: stock.count).upperBound,
            alternateStart: bounds.alternateStart, geometryWriteAuthorized: false, firmwareRestoreEligible: false,
            choices: ConsoleRestoreChoice.allCases.map { Choice(choice: $0, title: $0.title, explanation: $0.explanation, effects: $0.effects, executionAvailable: false) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(review)
    }
    // Schema 1 binds recovery semantics, while allowing older/localized presentation copy.
    // All decoded safety fields are explicit stored values; defaults must never mask JSON.
    private func validateReview(_ bytes: Data) throws {
        let receipt = try JSONDecoder().decode(Review.self, from: bytes)
        guard receipt.schemaVersion == 1, receipt.scope == "snes-recovery-review",
              receipt.expectedHWID == expectedHWID,
              receipt.originalImageSHA256 == BackupManifest.digest(stock), receipt.originalImageBytes == stock.count,
              receipt.activeStart == bounds.activeStart,
              receipt.activeExtentEnd == (try bounds.checkedExtent(byteCount: stock.count)).upperBound,
              receipt.alternateStart == bounds.alternateStart,
              !receipt.geometryWriteAuthorized, !receipt.firmwareRestoreEligible,
              receipt.choices.map(\.choice) == ConsoleRestoreChoice.allCases else { throw SNESOfflineSource.failure() }
        for choice in receipt.choices {
            guard !choice.executionAvailable, choice.effects == choice.choice.effects,
                  !choice.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !choice.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  choice.title.utf8.count <= 1024, choice.explanation.utf8.count <= 8192 else { throw SNESOfflineSource.failure() }
        }
    }
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try Task.checkCancellation(); try revalidate()
        var all = files; all["recovery-review.json"] = try review()
        guard var manifest = try JSONSerialization.jsonObject(with: sourceManifest) as? [String: Any] else { throw SNESOfflineSource.failure() }
        manifest["scope"] = "snes-original-startup-recovery"
        manifest["firmwareWritten"] = false
        manifest["firmwareRestoreEligible"] = false
        manifest["recoveryFiles"] = all.mapValues(BackupManifest.digest)
        let encoded = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        try revalidate()
        return (all, encoded)
    }
    static func loadPackage(directory: URL) throws -> Self {
        let source = try SNESOfflineSource.loadRecoveryPackage(snapshot: directory)
        let result = try Self(source: source, isPackage: true)
        let dir = try RestoreDirectory(directory)
        let raw = try dir.read("manifest.json", maximum: 65536)
        guard let manifest = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let hashes = manifest["recoveryFiles"] as? [String: String] else { throw SNESOfflineSource.failure() }
        let receipt = try dir.read("recovery-review.json", maximum: 32768)
        try result.validateReview(receipt)
        var expected = result.files; expected["recovery-review.json"] = receipt
        guard Set(hashes.keys) == Set(expected.keys),
              Set(try dir.names()) == Set(expected.keys).union(["manifest.json"]) else { throw SNESOfflineSource.failure() }
        for (name, bytes) in expected {
            guard hashes[name] == BackupManifest.digest(bytes),
                  try dir.read(name, maximum: max(bytes.count, 1)) == bytes else { throw SNESOfflineSource.failure() }
        }
        try source.revalidate(); try dir.check()
        return result
    }
}
