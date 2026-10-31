import Foundation

/// Review context only. A selected model or local backup never grants a write capability.
struct ConsoleRecoveryContext: Hashable, Sendable {
    let console: ConsoleType
    let isConnected: Bool
    init(connected: ConsoleType, selected: ConsoleType) {
        isConnected = connected != .unknown
        console = isConnected ? connected : selected
    }
    var choices: [ConsoleRestoreChoice] { ConsoleRestoreChoice.allCases }
    var canExecute: Bool { false }
    var targetDescription: String {
        (isConnected ? "Connected console: " : "Selected library: ") + console.displayName
    }
}
