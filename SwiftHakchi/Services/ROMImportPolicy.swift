import Foundation
import SwiftHakchiCore

/// Shared picker/import policy; extensions do not establish emulator compatibility.
enum ROMImportPolicy {
    static let archiveExtensions: Set<String> = ["zip", "7z"]
    static func extensions(for console: ConsoleType) -> [String] {
        if console.isNES { return ["nes", "fds"] }
        if console.isSNES { return ["sfc", "smc", "sfrom"] }
        if console == .megaDrive { return ["md", "bin", "gen"] }
        return []
    }
    static let guidance = "Add game files or ZIP/7z archives. Only extracted games are copied into the library; your original files stay on your Mac. NES: .nes/.fds. SNES: .sfc/.smc/.sfrom. Genesis: .md/.bin/.gen. Importing does not change a console. Sync Library checks compatibility for a supported connected console; Genesis console sync is not available yet."
    static func pickerMessage(for console:ConsoleType)->String {
        let types=extensions(for:console).map{"."+$0}.joined(separator:", ")
        return "Choose \(types) files or ZIP/7z archives.\nGames are copied to this Mac; your original files stay unchanged."
    }
    /// Top-level only; documents/subfolders are skipped, matching symlinks are rejected.
    static func collectFolder(_ directory: URL, for console: ConsoleType) throws -> [URL] {
        let allowed = Set(extensions(for: console)).union(archiveExtensions)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let files = entries.filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { throw SyncPlanError.invalidInput("No supported ROMs or ZIP/7z archives were found in that folder. Subfolders are not scanned.") }
        try validate(files, for: console)
        return files
    }

    static func validate(_ urls: [URL], for console: ConsoleType) throws {
        let allowed = extensions(for: console)
        guard !allowed.isEmpty else { throw SyncPlanError.invalidInput("Choose an NES, SNES or Genesis library before adding ROMs.") }
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard allowed.contains(ext) || archiveExtensions.contains(ext) else {
                let advice = "Use " + allowed.map { "." + $0 }.joined(separator: ", ") + " or a ZIP/7z archive containing those files. Renaming a file does not convert it."
                throw SyncPlanError.invalidInput(url.lastPathComponent + ": " + advice)
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SyncPlanError.invalidInput("Add ordinary ROM files, not folders or symbolic links.")
            }
        }
    }
}
