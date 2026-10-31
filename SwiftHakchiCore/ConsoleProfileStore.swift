import Foundation

public struct ConsoleProfileStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load(deviceID: String, systemCode: String) throws -> ConsoleProfile? {
        let identity = ConsoleProfile(deviceID: deviceID, systemCode: systemCode)
        let path = directory.appendingPathComponent(identity.storageKey + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let profile = try JSONDecoder().decode(ConsoleProfile.self, from: Data(contentsOf: path))
        guard profile.deviceID == deviceID, profile.systemCode == systemCode else { throw SyncPlanError.invalidInput("The selection profile belongs to another console.") }
        return profile
    }
    public func save(_ profile: ConsoleProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(profile).write(to: directory.appendingPathComponent(profile.storageKey + ".json"), options: .atomic)
    }
}
