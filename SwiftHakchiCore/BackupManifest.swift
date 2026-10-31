import Foundation
import CryptoKit

public struct BackupManifest: Codable, Sendable {
    public let profile: ConsoleProfile
    public let createdAt: Date
    public let sourcePaths: [String]
    public let archiveFilename: String
    public let byteCount: Int
    public let sha256: String

    public init(profile: ConsoleProfile, sourcePaths: [String], archiveFilename: String, data: Data) {
        self.profile = profile; self.createdAt = Date(); self.sourcePaths = sourcePaths
        self.archiveFilename = archiveFilename; self.byteCount = data.count
        self.sha256 = Self.digest(data)
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func verify(archive: Data, for profile: ConsoleProfile) throws {
        guard self.profile.deviceID == profile.deviceID, self.profile.systemCode == profile.systemCode,
              byteCount == archive.count, sha256 == Self.digest(archive) else {
            throw SyncPlanError.invalidInput("Backup identity or checksum verification failed.")
        }
    }
}
