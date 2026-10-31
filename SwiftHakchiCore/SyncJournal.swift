import Foundation

public struct SyncJournal: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case staging, activating, verified }
    public let id: UUID
    public let profile: ConsoleProfile
    public let activeBase: String
    public let oldPage: String
    public let originalGamesPath: String
    public let expectedCodes: Set<String>
    public let menuStatePath: String?
    public let oldMenuState: Data?
    public var phase: Phase
    public var stage: String { activeBase + ".stage-" + id.uuidString }
    public var previous: String { activeBase + ".previous-" + id.uuidString }
    public var failed: String { activeBase + ".failed-" + id.uuidString }

    public init(profile: ConsoleProfile, activeBase: String, oldPage: String, originalGamesPath: String, expectedCodes: Set<String>, menuStatePath: String? = nil, oldMenuState: Data? = nil) {
        id = UUID(); self.profile = profile; self.activeBase = activeBase; self.oldPage = oldPage
        self.originalGamesPath = originalGamesPath; self.expectedCodes = expectedCodes
        self.menuStatePath = menuStatePath; self.oldMenuState = oldMenuState; phase = .staging
    }
}
