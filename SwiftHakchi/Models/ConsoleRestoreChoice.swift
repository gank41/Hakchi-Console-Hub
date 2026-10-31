import Foundation

/// Review choices only. Selecting a choice never grants a delete or firmware capability.
enum ConsoleRestoreChoice: String, Codable, CaseIterable, Sendable {
    case returnToBuiltInGames, restoreOriginalStartup, eraseSavesAndSettings
    struct Effects: Codable, Equatable, Sendable {
        let removesAddedGames: Bool, modifiesStartup: Bool, erasesSavesAndSettings: Bool
        let changesMacLibrary: Bool
        let requiresCurrentDeviceBackup: Bool
    }
    var title: String {
        switch self {
        case .returnToBuiltInGames: return "Return to Built-in Games"
        case .restoreOriginalStartup: return "Restore Original Startup"
        case .eraseSavesAndSettings: return "Erase Console Saves and Settings"
        }
    }
    var explanation: String {
        switch self {
        case .returnToBuiltInGames: return "Remove added games from this console and show its original games. Keep saves, settings and your Mac library."
        case .restoreOriginalStartup: return "Use this console’s recovery backup to restore its original startup software. Keep saves and your Mac library."
        case .eraseSavesAndSettings: return "Erase this console’s saves and settings after a separate confirmation. Keep your Mac library."
        }
    }
    var effects: Effects {
        .init(removesAddedGames: self == .returnToBuiltInGames, modifiesStartup: self == .restoreOriginalStartup,
              erasesSavesAndSettings: self == .eraseSavesAndSettings, changesMacLibrary: false, requiresCurrentDeviceBackup: true)
    }
}
