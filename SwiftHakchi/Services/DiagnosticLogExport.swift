import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum DiagnosticLogExport {
    enum ExportError: LocalizedError {
        case noLogs
        var errorDescription: String? { "There are no troubleshooting logs to export yet. Try again after the problem occurs." }
    }
    private static let maxFileSize = 16 * 1024 * 1024
    private static let maxTotalSize = 64 * 1024 * 1024

    /// Exports app log files only; games, backups, settings and system logs are excluded.
    static func create(logs: URL, destination: URL) throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("Hakchi-Logs-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let contents = temporary.appendingPathComponent("contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let names = fm.fileExists(atPath: logs.path) ? try fm.contentsOfDirectory(atPath: logs.path) : []
        var count = 0, total = 0
        for name in names.sorted() where !name.hasPrefix(".") && (name.hasSuffix(".log") || name.hasSuffix(".jsonl")) {
            let source = logs.appendingPathComponent(name)
            var prior = stat()
            guard lstat(source.path, &prior) == 0 else { throw CocoaError(.fileReadUnknown) }
            guard (prior.st_mode & S_IFMT) == S_IFREG else { continue }
            let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_dev == prior.st_dev, info.st_ino == prior.st_ino else { try? handle.close(); throw CocoaError(.fileReadUnknown) }
            guard info.st_size >= 0, info.st_size <= maxFileSize else { throw CocoaError(.fileReadTooLarge) }
            var data = Data()
            while data.count <= maxFileSize {
                let chunk = try handle.read(upToCount: min(262_144, maxFileSize + 1 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            try handle.close()
            guard data.count <= maxFileSize, total <= maxTotalSize - data.count else { throw CocoaError(.fileReadTooLarge) }
            total += data.count; count += 1
            try data.write(to: contents.appendingPathComponent(name), options: .atomic)
        }
        guard count > 0 else { throw ExportError.noLogs }
        let readme = "Hakchi Console Hub troubleshooting logs\n\nThis archive contains \(count) app log file(s). Logs may include device identifiers, game names or file paths. Review them before sharing. Game files, backups and settings are not included.\n"
        try Data(readme.utf8).write(to: contents.appendingPathComponent("Read Me.txt"), options: .atomic)
        let archive = temporary.appendingPathComponent("logs.zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", contents.path, archive.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try Data(contentsOf: archive).write(to: destination, options: .atomic)
    }

    @MainActor static func present(logs: URL) {
        let panel = NSSavePanel()
        panel.title = "Export Troubleshooting Logs"
        panel.message = "Logs may include console identifiers, game names and file paths. Review the ZIP before sharing it."
        panel.nameFieldStringValue = "Hakchi Console Hub Logs.zip"
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try create(logs: logs, destination: destination) }.value
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                let alert = NSAlert(error: error); alert.messageText = "Couldn't Export Logs"; alert.runModal()
            }
        }
    }
}
