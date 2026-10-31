import Foundation
import CryptoKit

public struct ConsoleProfile: Codable, Equatable, Sendable {
    public let deviceID: String
    public let systemCode: String
    public var selectedCustomCodes: Set<String>
    public var hiddenStockCodes: Set<String>

    public init(deviceID: String, systemCode: String, selectedCustomCodes: Set<String> = [], hiddenStockCodes: Set<String> = []) {
        self.deviceID = deviceID
        self.systemCode = systemCode
        self.selectedCustomCodes = selectedCustomCodes
        self.hiddenStockCodes = hiddenStockCodes
    }

    public var storageKey: String {
        SHA256.hash(data: Data("\(deviceID)\n\(systemCode)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var supportsGameSync: Bool {
        !deviceID.isEmpty && ["nes-usa", "nes-jpn"].contains(systemCode)
    }
}
