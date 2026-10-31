import Foundation

public enum LibraryMigration {
    /// Copy an earlier managed library without merging or removing source files.
    public static func copy(from source: URL, to destination: URL) throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard source != destination, !destination.path.hasPrefix(source.path + "/") else {
            throw SyncPlanError.invalidInput("Choose a destination outside the earlier library.")
        }
        if FileManager.default.fileExists(atPath: destination.path),
           !(try FileManager.default.contentsOfDirectory(atPath: destination.path)).isEmpty {
            throw SyncPlanError.invalidInput("The destination library already contains games. Import individual ROMs instead of overwriting it.")
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".migration-" + UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
}
