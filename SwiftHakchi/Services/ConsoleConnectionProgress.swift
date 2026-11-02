import Foundation

enum ConsoleConnectionStage: String, Equatable, Sendable {
    case closingPrevious, openingUSB, identifyingConsole, checkingSetupFiles, verifyingConsole
    var title: String {
        switch self {
        case .closingPrevious: "Finishing the previous connection…"
        case .openingUSB: "Opening the console connection…"
        case .identifyingConsole: "Identifying the console…"
        case .checkingSetupFiles: "Checking setup files on this Mac…"
        case .verifyingConsole: "Checking the console connection…"
        }
    }
}

typealias ConsoleConnectionProgressSink = @Sendable (ConsoleConnectionStage) async -> Void

/// Presentation only: USB presence does not prove recovery or a connection.
enum ConsoleConnectionStatus: Equatable {
    case disconnected, connecting, connected(String), connectedLegacy, recoveryOrLegacyUSB, failed
    static func resolve(connected: Bool, legacy: Bool, console: ConsoleType,
                        stage: ConsoleConnectionStage?, recoveryUSB: Bool, hasError: Bool) -> Self {
        if stage != nil { return .connecting }
        if connected { return legacy ? .connectedLegacy : .connected(console.displayName) }
        if recoveryUSB { return .recoveryOrLegacyUSB }
        if hasError { return .failed }
        return .disconnected
    }
    var title: String {
        switch self {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected(let name): return "Connected — \(name)"
        case .connectedLegacy: return "Connected — NES"
        case .recoveryOrLegacyUSB: return "Console USB detected"
        case .failed: return "Connection needs attention"
        }
    }
}
