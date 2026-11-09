import Darwin
import Foundation

/// Copies a library snapshot as data. It never authorizes or contacts a console.
enum SNESPortableLibraryBackup {
    enum SyncPoint { case file, group, output, staging, destination }
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
    /// Write only through the already-open destination directory. A moved or
    /// substituted path must not redirect a write or chmod to another folder.
    static func writeForCopy(_ data: Data, name: String, folder: RestoreDirectory,
                             synchronize: (Int32) -> Int32) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw failure() }
        try folder.check()
        let fd = openat(folder.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            var held = stat(), named = stat()
            guard fchmod(fd, 0o600) == 0, fstat(fd, &held) == 0,
                  fstatat(folder.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  held.st_mode & S_IFMT == S_IFREG, held.st_nlink == 1, held.st_size == data.count,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                  synchronize(fd) == 0 else { throw failure() }
            try handle.close(); try folder.check()
        } catch { try? handle.close(); throw error }
    }
    static func copy(_ source: URL, to parentURL: URL,
                     synchronize: (Int32, SyncPoint) -> Int32 = { fd, _ in Darwin.fsync(fd) }) throws -> URL {
        let name = source.lastPathComponent, prefix = "SNES-Library-"
        guard source.isFileURL, name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
              name == prefix + id.uuidString else { throw failure() }
        let input = try RestoreDirectory(source), parent = try RestoreDirectory(parentURL)
        guard !parent.url.pathComponents.starts(with: input.url.pathComponents) else { throw failure() }
        var existing = stat()
        if fstatat(parent.fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            throw RecoveryProbeError.refused("A backup with this name is already in that folder. The existing backup was kept.")
        }
        guard errno == ENOENT else { throw failure() }
        let stagingName = ".portable-" + UUID().uuidString
        guard mkdirat(parent.fd, stagingName, 0o700) == 0 else { throw failure() }
        let stageURL = parent.url.appendingPathComponent(stagingName, isDirectory: true)
        let stage = try RestoreDirectory(stageURL)
        // Preserve incomplete copies. Recursive path deletion after an
        // identity check could remove an unrelated substituted directory.
        defer {
            if (try? parent.check()) != nil, (try? stage.check()) != nil,
               (try? stage.names().isEmpty) == true {
                _ = unlinkat(parent.fd, stagingName, AT_REMOVEDIR)
            }
        }
        var published = false
        do {
        guard mkdirat(stage.fd, name, 0o700) == 0 else { throw failure() }
        let outputURL = stageURL.appendingPathComponent(name, isDirectory: true)
        let output = try RestoreDirectory(outputURL)
        func syncDirectory(_ folder: RestoreDirectory, _ point: SyncPoint) throws {
            try folder.check()
            guard synchronize(folder.fd, point) == 0 else { throw failure() }
            try folder.check()
        }
        func write(_ data: Data, _ name: String, _ folder: RestoreDirectory) throws {
            try writeForCopy(data, name: name, folder: folder, synchronize: { synchronize($0, .file) })
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
            try from.check(); try syncDirectory(to, .group)
        }
        try input.check(); try syncDirectory(output, .output); try parent.check(); try Task.checkCancellation()
        let verified = try SNESLibraryBackup.open(directory: outputURL)
        try verified.validate(); try input.check(); try parent.check(); try syncDirectory(stage, .staging)
        guard renameatx_np(stage.fd, name, parent.fd, name, UInt32(RENAME_EXCL)) == 0 else { throw failure() }
        published = true
        let result = parent.url.appendingPathComponent(name, isDirectory: true)
        do {
            try syncDirectory(parent, .destination)
            let reopened = try SNESLibraryBackup.open(directory: result)
            guard reopened.manifestSHA256 == verified.manifestSHA256 else { throw failure() }
            try reopened.validate(); try parent.check()
        } catch {
            throw RecoveryProbeError.refused("A copy was created, but its final check did not finish. Keep the original and check the copied folder before using it. No console was changed.")
        }
        return result
        } catch {
            if published { throw error }
            guard (try? parent.check()) != nil, (try? stage.check()) != nil else {
                throw RecoveryProbeError.refused("The copy did not finish because a temporary folder moved or changed. Your original backup was kept. Check the destination before removing anything. No console was changed.")
            }
            throw RecoveryProbeError.refused("The copy did not finish. Your original backup was kept. An unfinished copy may remain in \(stageURL.path). No console was changed. \(error.localizedDescription)")
        }
    }
}
