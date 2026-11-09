import Foundation
import Darwin
import SwiftHakchiCore

struct RecoveryCheck: Sendable {
    enum Status: Sendable { case verified, missing, failed, unavailable }
    let status: Status
    let detail: String
    var path: URL? = nil
}

enum RecoveryScope: String, CaseIterable, Identifiable, Sendable {
    case gameLibrary, savesAndSettings, uninstall, stockKernel, fullFirmware
    var id: String { rawValue }
    var canExecute: Bool { false }
    var title: String {
        switch self {
        case .gameLibrary: return "Rebuild custom game library"
        case .savesAndSettings: return "Erase saves and settings"
        case .uninstall: return "Uninstall custom kernel"
        case .stockKernel: return "Restore stock kernel"
        case .fullFirmware: return "Reflash full firmware / root filesystem"
        }
    }
    var detail: String {
        switch self {
        case .gameLibrary: return "Requires a separate verified library-transfer and rollback workflow. It does not inherently require flashing."
        case .savesAndSettings: return "Erasing saves/settings is separate from removing custom games or restoring a kernel."
        case .uninstall: return "Requires a checked, journaled uninstall; the old reset script is not a complete stock restore."
        case .stockKernel: return "Requires device/family binding, recovery-boot validation, flash readback and a normal-boot HDMI test."
        case .fullFirmware: return "The recovered stock kernel is not a full NAND or root-filesystem image."
        }
    }
}

struct RecoveryReadinessReport: Sendable {
    let kernel: RecoveryCheck
    let payload: RecoveryCheck
    let warnings: [String]
    var scopes: [RecoveryScope] { RecoveryScope.allCases }
    var canReset: Bool { false }
}

/// File-only inspection. This actor has no console transport or mutation capability.
actor RecoveryPreflightService {
    private let payloadEvidence: @Sendable () async throws -> RecoveryPayloadEvidence
    init(payloadEvidence: @escaping @Sendable () async throws -> RecoveryPayloadEvidence = {
        try await PayloadService.shared.recoveryEvidence()
    }) { self.payloadEvidence = payloadEvidence }

    func inspect(backups: URL, console: ConsoleType = .nes) async -> RecoveryReadinessReport {
        guard console == .nes || console == .snesUsa else {
            let unavailable = RecoveryCheck(status: .unavailable,
                detail: "Recovery file checks are not available for this console model yet. Your backups and console are unchanged.")
            return RecoveryReadinessReport(kernel: unavailable, payload: unavailable, warnings: [])
        }
        let result = console == .nes ? Self.inspectStock(backups: backups) : Self.inspectSNES(backups: backups)
        let payload: RecoveryCheck
        if console == .snesUsa {
            payload = RecoveryCheck(status: .unavailable, detail: "A complete SNES factory reset is not available yet. Restoring the original startup uses a separate, reviewed process; it does not erase games or saves.")
        } else {
            do {
                let evidence = try await payloadEvidence()
                payload = RecoveryCheck(status: .verified, detail: "Audited bundled DRAM loader, hakchi module, base modules, U-Boot and custom recovery image match their pinned bytes. Custom recovery boot.img SHA256: \(evidence.bootImageSHA256). This does not validate booting or flashing them.")
            } catch { payload = RecoveryCheck(status: .failed, detail: error.localizedDescription) }
        }
        return RecoveryReadinessReport(kernel: result.0, payload: payload, warnings: result.1)
    }

    private static func inspectSNES(backups: URL) -> (RecoveryCheck, [String]) {
        let root = backups.standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else {
            return (RecoveryCheck(status: .failed, detail: "Choose a backup folder without folder aliases or symbolic links."), [])
        }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            return (RecoveryCheck(status: errno == ENOENT ? .missing : .failed,
                detail: "The Mac backup folder is missing or cannot be read.", path: root), [])
        }
        defer { close(descriptor) }
        do {
            let names = try RecoveryMaterialReader.candidateNames(directory: descriptor, prefixes: ["SNES-Recovery-Material-", "SNES-US-Setup-"])
            var found: URL?, warnings: [String] = []
            for name in names.sorted() {
                let candidate = root.appendingPathComponent(name)
                do {
                    let material = try name.hasPrefix("SNES-Recovery-Material-")
                        ? SNESRecoveryMaterial.loadPackage(directory: candidate) : SNESRecoveryMaterial.load(setup: candidate)
                    try material.revalidate()
                    if found == nil { found = candidate }
                } catch { warnings.append(name + ": " + error.localizedDescription) }
            }
            if let found {
                return (RecoveryCheck(status: .verified,
                    detail: "An original US SNES startup backup was verified on this Mac. The console identity must be checked again before using it. This check does not enable installation or restoration.", path: found), warnings)
            }
            return (RecoveryCheck(status: names.isEmpty ? .missing : .failed,
                detail: "No verified US SNES startup backup was found in this Mac backup folder. Use Prepare SNES Setup to save the original files first.", path: root), warnings)
        } catch { return (RecoveryCheck(status: .failed, detail: error.localizedDescription, path: root), []) }
    }

    private static func inspectStock(backups: URL) -> (RecoveryCheck, [String]) {
        let root = backups.standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else {
            return (RecoveryCheck(status: .failed, detail: "Backups must be an ordinary directory without symlink path components."), [])
        }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else {
            return (RecoveryCheck(status: errno == ENOENT ? .missing : .failed,
                                  detail: "Recovery Backups directory is missing or cannot be opened safely.", path: root), [])
        }
        defer { close(directory) }
        do {
            let names = try RecoveryMaterialReader.candidateNames(directory: directory)
            var found: [(URL, StockKernelEvidence)] = [], warnings: [String] = []
            for name in names.sorted() {
                let candidate = root.appendingPathComponent(name)
                let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { warnings.append("\(name): not an ordinary recovery directory."); continue }
                defer { close(fd) }
                do {
                    let data = try RecoveryMaterialReader.readFile(directory: fd, name: "kernel-stock-NES.img", maximumBytes: LegacyAndroidBootImage.maximumSize)
                    found.append((candidate.appendingPathComponent("kernel-stock-NES.img"), try StockKernelEvidence(data: data)))
                } catch { warnings.append("\(name): \(error.localizedDescription)") }
            }
            if let first = found.first {
                return (RecoveryCheck(status: .verified,
                    detail: "Recognized \(first.1.family) stock kernel: \(first.1.byteCount) bytes, SHA256 \(first.1.sha256). \(found.count) verified local copy/copies. Device identity and restore behavior remain unverified.", path: first.0), warnings)
            }
            return (RecoveryCheck(status: names.isEmpty ? .missing : .failed,
                detail: "No recognized stock kernel found. Keep kernel-stock-NES.img in a RecoveryMaterial-* folder under Backups. Unknown images remain backups; manifest eligibility claims are not used.", path: root), warnings)
        } catch { return (RecoveryCheck(status: .failed, detail: error.localizedDescription, path: root), []) }
    }
}

/// Ordinary file descriptors bound before reading; no following final-component links or FIFOs.
enum RecoveryMaterialReader {
    static func candidateNames(directory: Int32, prefixes: [String] = ["RecoveryMaterial-"]) throws -> [String] {
        let duplicated = dup(directory)
        guard duplicated >= 0 else { throw RecoveryImageError.invalid("Cannot inspect recovery directory.") }
        guard let stream = fdopendir(duplicated) else { close(duplicated); throw RecoveryImageError.invalid("Cannot enumerate recovery directory.") }
        defer { closedir(stream) }
        var names: [String] = [], total = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw RecoveryImageError.invalid("Recovery directory enumeration failed.") }
                break
            }
            total += 1
            guard total <= 4096 else { throw RecoveryImageError.invalid("Backups has more than 4096 entries; choose a smaller recovery workspace.") }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if prefixes.contains(where: { name.hasPrefix($0) }) {
                names.append(name)
                guard names.count <= 64 else { throw RecoveryImageError.invalid("More than 64 recovery candidates need manual review.") }
            }
        }
        return names
    }

    static func readFile(at url: URL, maximumBytes: Int, exactBytes: Int? = nil) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RecoveryImageError.invalid("Cannot safely open \(url.lastPathComponent).") }
        defer { close(fd) }
        return try read(fd: fd, maximumBytes: maximumBytes, exactBytes: exactBytes)
    }
    static func readFile(directory: Int32, name: String, maximumBytes: Int) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RecoveryImageError.invalid("Missing or linked \(name); no file was read.") }
        defer { close(fd) }
        return try read(fd: fd, maximumBytes: maximumBytes)
    }
    private static func read(fd: Int32, maximumBytes: Int, exactBytes: Int? = nil) throws -> Data {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maximumBytes,
              exactBytes.map({ before.st_size == $0 }) ?? true else {
            throw RecoveryImageError.invalid("Recovery input is not an ordinary file of the expected bounded size.")
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, count <= maximumBytes - result.count else { throw RecoveryImageError.invalid("Recovery input changed or could not be read within its size limit.") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, result.count == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw RecoveryImageError.invalid("Recovery input changed during inspection. Recheck after file activity stops.")
        }
        return result
    }
}
