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
        case .returnToBuiltInGames: return "Show the built-in games again. Your saves, settings and Mac library stay. You can choose whether to back up and remove the previous console copy."
        case .restoreOriginalStartup: return "Use this console’s recovery backup to restore its original startup software. Keep saves and your Mac library."
        case .eraseSavesAndSettings: return "Erase this console’s saves and settings after a separate confirmation. Keep your Mac library."
        }
    }
    var effects: Effects {
        .init(removesAddedGames: self == .returnToBuiltInGames, modifiesStartup: self == .restoreOriginalStartup,
              erasesSavesAndSettings: self == .eraseSavesAndSettings, changesMacLibrary: false, requiresCurrentDeviceBackup: true)
    }
}
