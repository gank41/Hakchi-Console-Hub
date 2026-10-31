import Foundation
import SWCompression
import SwiftHakchiCore

/// Expands supported ROMs into a disposable directory before normal library import.
/// The archive itself is never copied to the managed Games folder.
enum ROMArchiveImporter {
    private static let maximumArchiveBytes = 128 * 1024 * 1024
    private static let maximumExpandedBytes = 256 * 1024 * 1024
    private static let maximumEntryBytes = 64 * 1024 * 1024
    private static let maximumEntries = 512

    private struct EntryInfo {
        let name: String
        let type: ContainerEntryType
        let size: Int?
    }

    static func materialize(_ urls: [URL], for console: ConsoleType, in temporaryDirectory: URL) throws -> [URL] {
        try ROMImportPolicy.validate(urls, for: console)
        let supported = Set(ROMImportPolicy.extensions(for: console))
        var sources: [URL] = []
        for (index, url) in urls.enumerated() {
            guard ROMImportPolicy.archiveExtensions.contains(url.pathExtension.lowercased()) else {
                sources.append(url)
                continue
            }
            let destination = temporaryDirectory.appendingPathComponent(String(index), isDirectory: true)
            let extracted = try extract(url, supported: supported, into: destination)
            sources.append(contentsOf: extracted)
        }
        try ROMImportPolicy.validate(sources, for: console)
        return sources
    }

    private static func extract(_ url: URL, supported: Set<String>, into destination: URL) throws -> [URL] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let archiveSize = values.fileSize, archiveSize >= 0, archiveSize <= maximumArchiveBytes else {
            throw SyncPlanError.invalidInput("\(url.lastPathComponent): archive must be an ordinary file no larger than 128 MiB.")
        }
        let container = try Data(contentsOf: url, options: .mappedIfSafe)
        guard container.count == archiveSize else {
            throw SyncPlanError.invalidInput("\(url.lastPathComponent): archive changed while reading it.")
        }
        let isZIP = url.pathExtension.lowercased() == "zip"
        let infos: [EntryInfo]
        do {
            if isZIP {
                infos = try ZipContainer.info(container: container).map { EntryInfo(name: $0.name, type: $0.type, size: $0.size) }
            } else {
                infos = try SevenZipContainer.info(container: container).map { EntryInfo(name: $0.name, type: $0.type, size: $0.size) }
            }
        } catch {
            throw SyncPlanError.invalidInput("\(url.lastPathComponent): could not read this archive (\(error.localizedDescription)).")
        }
        guard infos.count <= maximumEntries else {
            throw SyncPlanError.invalidInput("\(url.lastPathComponent): archive has too many files (limit: 512).")
        }
        var totalBytes = 0
        var selected: [Int: String] = [:]
        var names = Set<String>()
        for (index, info) in infos.enumerated() {
            let normalized = info.name.replacingOccurrences(of: "\\", with: "/")
            let path = info.type == .directory && normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !normalized.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !info.name.contains("\0") else {
                throw SyncPlanError.invalidInput("\(url.lastPathComponent): archive contains an unsafe file path.")
            }
            if info.type == .directory { continue }
            guard info.type == .regular, let size = info.size, size >= 0, size <= maximumEntryBytes,
                  totalBytes <= maximumExpandedBytes - size else {
                throw SyncPlanError.invalidInput("\(url.lastPathComponent): archive contains an unsupported or oversized file.")
            }
            totalBytes += size
            let filename = String(parts.last!)
            if filename.hasPrefix("._") || parts.contains(where: { $0.caseInsensitiveCompare("__MACOSX") == .orderedSame }) {
                continue
            }
            guard supported.contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) else { continue }
            guard names.insert(filename.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw SyncPlanError.invalidInput("\(url.lastPathComponent): two ROMs have the same filename. Extract and rename them before importing.")
            }
            selected[index] = filename
        }
        guard !selected.isEmpty else {
            throw SyncPlanError.invalidInput("\(url.lastPathComponent): no supported \(supported.sorted().map { "." + $0 }.joined(separator: ", ")) ROM was found.")
        }
        let entries: [(EntryInfo, Data?)]
        do {
            if isZIP {
                entries = try ZipContainer.open(container: container).map { (EntryInfo(name: $0.info.name, type: $0.info.type, size: $0.info.size), $0.data) }
            } else {
                entries = try SevenZipContainer.open(container: container).map { (EntryInfo(name: $0.info.name, type: $0.info.type, size: $0.info.size), $0.data) }
            }
        } catch {
            throw SyncPlanError.invalidInput("\(url.lastPathComponent): extraction failed (\(error.localizedDescription)).")
        }
        guard entries.count == infos.count else {
            throw SyncPlanError.invalidInput("\(url.lastPathComponent): archive changed while reading it.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var output: [URL] = []
        for (index, filename) in selected.sorted(by: { $0.key < $1.key }) {
            let entry = entries[index]
            guard entry.0.name == infos[index].name, entry.0.type == .regular,
                  let data = entry.1, data.count == infos[index].size else {
                throw SyncPlanError.invalidInput("\(url.lastPathComponent): extracted ROM did not match the archive listing.")
            }
            let rom = destination.appendingPathComponent(filename)
            try data.write(to: rom, options: .atomic)
            output.append(rom)
        }
        return output
    }
}
