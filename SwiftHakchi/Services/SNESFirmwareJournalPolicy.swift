import Foundation

/// Stable per-user state, independent of library/backup-folder preferences.
enum SNESFirmwareJournalPolicy {
    static func root()throws->URL {
        guard let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else {throw RestoreDirectory.failure()}
        return support.appendingPathComponent("SwiftHakchi/FirmwareTransactions/SNES",isDirectory:true).standardizedFileURL
    }
    static func requireOperation(_ url:URL)throws {
        let value=url.standardizedFileURL,prefix="SNESFirmware-"
        guard value.deletingLastPathComponent()==(try root()),value.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString:String(value.lastPathComponent.dropFirst(prefix.count))) != nil else {
            throw RecoveryProbeError.refused("Open the saved console update in Swift Hakchi’s operation history. Changing the Backups folder does not start a new firmware history.")
        }
    }
    static func ensureRoot()throws->URL {
        let value=try root()
        guard value==value.resolvingSymlinksInPath() else {throw RestoreDirectory.failure()}
        try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let checked=try RestoreDirectory(value);try checked.check();return checked.url
    }
}
