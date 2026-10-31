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
