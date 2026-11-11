import Darwin
import Foundation

/// Copies a checked, console-specific full-data backup. This does not restore
/// data, authorize a write, or make the backup suitable for another console.
enum SNESPortableDataSnapshot {
    enum SyncPoint { case file, output, staging, destination }
    private static func failure() -> RecoveryProbeError {
        .refused("The full-data backup could not be copied and checked. Keep the original. No console was changed.")
    }

    /// Check all files without changing them or contacting a console. The
    /// identity in the manifest is a claim, not proof of physical origin.
    static func inspect(directory: URL) throws -> SNESDataSnapshotPackage {
        do {
            let input = try RestoreDirectory(directory)
            let manifest = try JSONDecoder().decode(SNESDataSnapshotResult.Manifest.self, from: input.read("manifest.json", maximum: 65_536))
            try manifest.binding.validate(); try input.check()
            return try SNESDataSnapshotPackage.load(directory: input.url, expectedHWID: manifest.binding.expectedHWID)
        } catch is CancellationError { throw CancellationError() }
        catch { throw RecoveryProbeError.refused("The full-data backup could not be checked. Keep the original. No console was changed.") }
    }

    /// Check the backup's internal integrity before copying an existing folder.
    static func copy(directory: URL, to parentURL: URL) throws -> URL {
        return try copy(inspect(directory: directory), to: parentURL)
    }

    static func copy(_ source: SNESDataSnapshotPackage, to parentURL: URL,
                     synchronize: (Int32, SyncPoint) -> Int32 = { fd, _ in Darwin.fsync(fd) }) throws -> URL {
        try source.revalidate()
        let name = source.directory.lastPathComponent, prefix = "SNES-Current-Data-"
        guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
              name == prefix + id.uuidString else { throw failure() }
        let input = try RestoreDirectory(source.directory), parent = try RestoreDirectory(parentURL)
        guard !parent.url.pathComponents.starts(with: input.url.pathComponents) else { throw failure() }
        var existing = stat()
        guard fstatat(parent.fd, name, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw RecoveryProbeError.refused("A backup with this name is already in that folder. The existing backup was kept.")
        }
        let stagingName = ".data-copy-" + UUID().uuidString
        guard mkdirat(parent.fd, stagingName, 0o700) == 0 else { throw failure() }
        let stageURL = parent.url.appendingPathComponent(stagingName, isDirectory: true)
        let stage = try RestoreDirectory(stageURL)
        // Never recursively remove a destination path after checking it: it
        // could have been replaced in between. Keep incomplete data for review.
        // On success the stage is empty; unlinkat can remove only an empty dir.
        defer {
            if (try? parent.check()) != nil, (try? stage.check()) != nil,
               (try? stage.names().isEmpty) == true {
                _ = unlinkat(parent.fd, stagingName, AT_REMOVEDIR)
            }
        }
        var published = false
        do {
        // Probe exclusive rename before the large copy; some volumes do not
        // implement it. The final rename still has to succeed separately.
        let first = openat(stage.fd, "rename-probe-a", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard first >= 0 else { throw failure() }; close(first)
        let second = openat(stage.fd, "rename-probe-b", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard second >= 0 else { throw failure() }; close(second)
        guard renameatx_np(stage.fd, "rename-probe-a", stage.fd, "rename-probe-b", UInt32(RENAME_EXCL)) != 0, errno == EEXIST,
              unlinkat(stage.fd, "rename-probe-b", 0) == 0,
              renameatx_np(stage.fd, "rename-probe-a", stage.fd, "rename-probe-b", UInt32(RENAME_EXCL)) == 0,
              unlinkat(stage.fd, "rename-probe-b", 0) == 0 else {
            throw RecoveryProbeError.refused("This location could not safely protect an existing backup. Try a folder on this Mac or another drive.")
        }
        guard mkdirat(stage.fd, name, 0o700) == 0 else { throw failure() }
        let outputURL = stageURL.appendingPathComponent(name, isDirectory: true)
        let output = try RestoreDirectory(outputURL)
        func sync(_ directory: RestoreDirectory, _ point: SyncPoint) throws {
            try directory.check(); guard synchronize(directory.fd, point) == 0 else { throw failure() }; try directory.check()
        }
        func write(_ bytes: Data, _ file: String) throws {
            let fd = openat(output.fd, file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw failure() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: bytes)
                var held = stat(), named = stat()
                guard fstat(fd, &held) == 0, fstatat(output.fd, file, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      held.st_mode & S_IFMT == S_IFREG, held.st_nlink == 1, held.st_size == bytes.count,
                      held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                      synchronize(fd, .file) == 0 else { throw failure() }
                try handle.close(); try output.check()
            } catch { try? handle.close(); throw error }
        }
        let names = try input.names()
        for file in names {
            try Task.checkCancellation()
            let maximum: Int
            switch file {
            case "manifest.json": maximum = 65_536
            case "partitions.txt": maximum = 16_384
            case "data-header.bin": maximum = 2_048
            case "boot1.bin": maximum = RecoveryBoot1Read.maximumSize
            case "stock.img": maximum = 2_736_128
            default:
                guard file.range(of: #"^data-[0-9]{4}\.bin$"#, options: .regularExpression) != nil else { throw failure() }
                continue
            }
            try write(input.read(file, maximum: maximum), file)
        }
        try source.streamVerifiedChunks { index, bytes in
            let name = SNESDataSnapshotPlan.name(index)
            guard names.contains(name) else { throw failure() }
            try input.check(); try write(bytes, name); try input.check()
        }
        try input.check(); try sync(output, .output)
        let checked = try SNESDataSnapshotPackage.load(directory: outputURL, expectedHWID: source.binding.expectedHWID)
        guard checked.sha256 == source.sha256, checked.manifestSHA256 == source.manifestSHA256,
              checked.binding == source.binding else { throw failure() }
        try Task.checkCancellation(); try sync(stage, .staging); try parent.check()
        guard renameatx_np(stage.fd, name, parent.fd, name, UInt32(RENAME_EXCL)) == 0 else { throw failure() }
        published = true
        let result = parent.url.appendingPathComponent(name, isDirectory: true)
        do {
            try sync(parent, .destination)
            let reopened = try SNESDataSnapshotPackage.load(directory: result, expectedHWID: source.binding.expectedHWID)
            guard reopened.sha256 == source.sha256, reopened.manifestSHA256 == source.manifestSHA256,
                  reopened.binding == source.binding else { throw failure() }
            try parent.check()
        } catch {
            throw RecoveryProbeError.refused("A copy was created, but its final check did not finish. Keep the original and check the copied folder. No console was changed.")
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
