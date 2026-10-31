import Foundation

struct LegacyMenuStageManifest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case directory, regular, symbolicLink }

    struct Entry: Codable, Sendable {
        let relativePath: String
        let kind: Kind
        let byteCount: Int64
        let sha256: String?
        let linkTarget: String?
    }

    let reviewSHA256: String
    let menuDirectory: URL
    let archiveURL: URL
    let entries: [Entry]
    let treeSHA256: String
    let archiveSHA256: String
    let archiveBytes: Int64
    /// Capacity is part of the review hash. Reusing an older Mac backup must not
    /// replace this frozen report when an inactive operation is reopened.
    var reviewReport: LegacyConsoleReport? = nil
}
