import Darwin
import Foundation

/// Copies a library snapshot as data. It never authorizes or contacts a console.
enum SNESPortableLibraryBackup {
    private static func failure() -> RecoveryProbeError {
        .refused("This backup could not be copied and verified. Keep the original and check the selected folders. No console was changed.")
    }
    private static func read(_ name: String, from folder: RestoreDirectory, maximum: Int) throws -> Data {
        try folder.check()
        let fd = openat(folder.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximum else { throw failure() }
        var bytes = Data()
        while bytes.count <= maximum {
            let part = try handle.read(upToCount: min(262_144, maximum + 1 - bytes.count)) ?? Data()
            if part.isEmpty { break }; bytes.append(part)
        }
        guard bytes.count == before.st_size, fstat(fd, &after) == 0,
              fstatat(folder.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              SNESLibrarySourceFile.Identity(before) == SNESLibrarySourceFile.Identity(after),
              SNESLibrarySourceFile.Identity(before) == SNESLibrarySourceFile.Identity(named) else { throw failure() }
        try folder.check(); return bytes
    }
    static func copy(_ source: URL, to parentURL: URL) throws -> URL {
        let name = source.lastPathComponent, prefix = "SNES-Library-"
        guard source.isFileURL, name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
              name == prefix + id.uuidString else { throw failure() }
        let input = try RestoreDirectory(source), parent = try RestoreDirectory(parentURL)
        var existing = stat()
        if fstatat(parent.fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            throw RecoveryProbeError.refused("A backup with this name is already in that folder. The existing backup was kept.")
        }
        guard errno == ENOENT else { throw failure() }
        let stagingName = ".portable-" + UUID().uuidString
        guard mkdirat(parent.fd, stagingName, 0o700) == 0 else { throw failure() }
        let stageURL = parent.url.appendingPathComponent(stagingName, isDirectory: true)
        let stage = try RestoreDirectory(stageURL)
        defer { if (try? parent.check()) != nil && (try? stage.check()) != nil { try? FileManager.default.removeItem(at: stageURL) } }
        guard mkdirat(stage.fd, name, 0o700) == 0 else { throw failure() }
        let outputURL = stageURL.appendingPathComponent(name, isDirectory: true)
        let output = try RestoreDirectory(outputURL)
        func write(_ data: Data, _ name: String, _ folder: RestoreDirectory) throws {
            let url = folder.url.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try folder.check()
        }
        let names = try input.names().filter { $0 != ".DS_Store" }
        let groups = names.filter { $0.range(of: #"^data-[0-7]$"#, options: .regularExpression) != nil }
        guard names.count == groups.count + 1, names.contains("manifest.json") else { throw failure() }
        try write(read("manifest.json", from: input, maximum: 24 * 1024 * 1024), "manifest.json", output)
        var total = 0, count = 0
        for groupName in groups {
            try Task.checkCancellation()
            let from = try RestoreDirectory(input.url.appendingPathComponent(groupName))
            guard mkdirat(output.fd, groupName, 0o700) == 0 else { throw failure() }
            let to = try RestoreDirectory(output.url.appendingPathComponent(groupName))
            let files = try from.names().filter { $0 != ".DS_Store" }
            guard files.count <= 1024 else { throw failure() }
            for file in files {
                guard file.range(of: #"^file-[0-9]{4}\.bin$"#, options: .regularExpression) != nil else { throw failure() }
                let data = try read(file, from: from, maximum: 16 * 1024 * 1024)
                count += 1; total += data.count
                guard count <= 8192, total <= 1024 * 1024 * 1024 else { throw failure() }
                try write(data, file, to)
            }
            try from.check(); try to.check()
        }
        try input.check(); try output.check(); try parent.check(); try Task.checkCancellation()
        let verified = try SNESLibraryBackup.open(directory: outputURL)
        try verified.validate(); try input.check(); try parent.check(); try stage.check()
        guard renameatx_np(stage.fd, name, parent.fd, name, UInt32(RENAME_EXCL)) == 0 else { throw failure() }
        let result = parent.url.appendingPathComponent(name, isDirectory: true)
        do {
            let reopened = try SNESLibraryBackup.open(directory: result)
            guard reopened.manifestSHA256 == verified.manifestSHA256 else { throw failure() }
            try reopened.validate(); try parent.check()
        } catch {
            throw RecoveryProbeError.refused("A copy was created, but its final check did not finish. Keep the original and check the copied folder before using it. No console was changed.")
        }
        return result
    }
}
