import Foundation

/// Windows Structure menu choices. The count is games, excluding navigation.
public enum ConsoleMenuLimit: Int, Codable, CaseIterable, Identifiable, Sendable {
    case twenty = 20, twentyFive = 25, thirty = 30, thirtyFive = 35
    case forty = 40, fortyFive = 45, fifty = 50, sixty = 60
    case seventy = 70, eighty = 80, ninety = 90, oneHundred = 100

    public var id: Int { rawValue }
    public var isNotRecommended: Bool { rawValue >= 50 }
    public var menuTitle: String { isNotRecommended ? "\(rawValue) (not recommended)" : "\(rawValue)" }
}
