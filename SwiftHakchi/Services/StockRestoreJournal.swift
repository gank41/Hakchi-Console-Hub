import Foundation
import Darwin
import SwiftHakchiCore

/// Every app-dispatched firmware transaction uses one stable root inside the
/// user's requested NES workspace, so an unresolved write cannot disappear
/// when a different folder is selected.
enum RecoveryFirmwareJournalPolicy {
    // The single-account development restriction is not suitable for a public
    // build. Keep firmware writes unavailable until general recovery is verified.
    static func requireOwner(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             uid: uid_t = geteuid(), realUID: uid_t = getuid()) throws {
        throw RecoveryProbeError.refused("Firmware recovery is not available in this preview. No console command was sent.")
    }
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hakchi Console Hub/Backups/StockKernelRestoreJournals", isDirectory: true)
            .standardizedFileURL
    }
    static func require(_ candidate: URL) throws {
        try requireOwner()
        guard candidate.standardizedFileURL == root else {
            throw RecoveryProbeError.refused("Firmware operations require the app's fixed recovery journal folder. Open the existing operation there; no console command was sent.")
        }
    }
    static func ensureRoot() throws -> URL {
        try requireOwner()
        let destination = root
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let checked = try RestoreDirectory(destination)
        try checked.check()
        return checked.url
    }
}

actor StockRestoreJournal {
    enum Phase: String, Codable, Sendable {
        case prepared, preflightVerified, burnIntent, readbackVerified, menuAccepted, stoppedBeforeWrite, uncertain
        func permits(_ next: Self) -> Bool {
            switch (self, next) {
            case (.prepared,.preflightVerified), (.prepared,.stoppedBeforeWrite),
                 (.preflightVerified,.burnIntent), (.preflightVerified,.stoppedBeforeWrite),
                 (.burnIntent,.readbackVerified), (.burnIntent,.uncertain),
                 (.readbackVerified,.menuAccepted): return true
            default: return false
            }
        }
        var unresolved: Bool { [.burnIntent,.uncertain,.readbackVerified].contains(self) }
    }
    struct Prepared: Sendable { let operation: URL; let reviewSHA256: String }
    private struct Record: Codable {
        let phase: Phase
        let planSHA256: String
        let previousSHA256: String?
    }
    private let storage: RestoreJournalStorage
    let reviewSHA256: String
    init(operation: URL, reviewSHA256: String,
         synchronize: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }) throws {
        guard reviewSHA256.count == 64, StockRestoreMaterial.hex(reviewSHA256) else { throw RestoreDirectory.failure() }
        let storage = try RestoreJournalStorage(root: operation.deletingLastPathComponent(), operation: operation, synchronize: synchronize)
        self.storage = storage; self.reviewSHA256 = reviewSHA256
        try Self.checkOthers(storage, excluding: operation.lastPathComponent)
        _ = try Self.load(storage.operation!, review: reviewSHA256)
    }
    static func prepare(material: StockRestoreMaterial, root: URL) throws -> Prepared {
        try Task.checkCancellation()
        try material.validateIntegrity()
        let storage = try RestoreJournalStorage(root: root)
        try checkOthers(storage, excluding: nil)
        let name = "StockKernelRestore-" + material.plan.id.uuidString
        guard mkdirat(storage.root.fd, name, 0o700) == 0 else { throw RestoreDirectory.failure() }
        let operation = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
        guard fchmod(operation.fd, 0o700) == 0 else { throw RestoreDirectory.failure() }
        try storage.write(material.stock, name: "stock.img", directory: operation)
        try storage.write(material.preimage, name: "preimage.img", directory: operation)
        let plan = try encode(material.plan), review = BackupManifest.digest(plan)
        try storage.write(plan, name: "plan.json", directory: operation)
        try storage.write(encode(Record(phase: .prepared, planSHA256: review, previousSHA256: nil)), name: "0000.json", directory: operation)
        try storage.sync(operation)
        try storage.sync(storage.root)
        try operation.check()
        try storage.closeLease()
        return Prepared(operation: operation.url, reviewSHA256: review)
    }
    /// Release the operation lease deterministically; all later access refuses.
    func close() throws { try storage.closeLease() }
    func phase() throws -> Phase { try state().phase }
    func verifiedMaterial() throws -> StockRestoreMaterial {
        let data = try state().material
        try data.validateForRestore()
        return data
    }
    func append(_ phase: Phase) throws {
        try Task.checkCancellation()
        let current = try state()
        guard current.phase.permits(phase) else { throw RestoreDirectory.failure() }
        try storage.write(Self.encode(Record(phase: phase, planSHA256: reviewSHA256, previousSHA256: current.lastSHA)),
                          name: String(format: "%04d.json", current.count), directory: storage.operation!)
        try storage.sync(storage.operation!)
        try storage.sync(storage.root)
        let after = try state()
        guard after.phase == phase, after.count == current.count + 1 else { throw RestoreDirectory.failure() }
    }
    private func state() throws -> State {
        try storage.checkLock()
        try Self.checkOthers(storage, excluding: storage.operation!.url.lastPathComponent)
        return try Self.load(storage.operation!, review: reviewSHA256)
    }
    private struct State {
        let phase: Phase; let count: Int; let lastSHA: String; let material: StockRestoreMaterial
    }
    private static func load(_ directory: RestoreDirectory, review: String) throws -> State {
        let planData = try directory.read("plan.json", maximum: 65536)
        guard BackupManifest.digest(planData) == review else { throw RestoreDirectory.failure() }
        let plan = try JSONDecoder().decode(StockRestorePlan.self, from: planData)
        guard directory.url.lastPathComponent == "StockKernelRestore-" + plan.id.uuidString else { throw RestoreDirectory.failure() }
        let material = try StockRestoreMaterial(plan: plan, stock: directory.read("stock.img"), preimage: directory.read("preimage.img"))
        try material.validateIntegrity()
        let names = try directory.names()
        let events = names.filter { $0 != "plan.json" && $0 != "stock.img" && $0 != "preimage.img" }
        guard !events.isEmpty, events.count <= 8 else { throw RestoreDirectory.failure() }
        var previous: String?, phase: Phase?
        for (index, name) in events.enumerated() {
            guard name == String(format: "%04d.json", index) else { throw RestoreDirectory.failure() }
            let bytes = try directory.read(name, maximum: 65536)
            let record = try JSONDecoder().decode(Record.self, from: bytes)
            guard record.planSHA256 == review, record.previousSHA256 == previous,
                  phase.map({ $0.permits(record.phase) }) ?? (record.phase == .prepared) else { throw RestoreDirectory.failure() }
            phase = record.phase; previous = BackupManifest.digest(bytes)
        }
        return State(phase: phase!, count: events.count, lastSHA: previous!, material: material)
    }
    private static func checkOthers(_ storage: RestoreJournalStorage, excluding: String?) throws {
        try storage.checkLock()
        let names = try storage.root.names().filter {
            ($0.hasPrefix("StockKernelRestore-") || $0.hasPrefix("LegacyBoot2Activation-")) && $0 != excluding
        }
        guard names.count <= 64 else { throw RestoreDirectory.failure() }
        for name in names {
            let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
            if name.hasPrefix("LegacyBoot2Activation-") {
                guard try !LegacyBoot2ActivationJournal.unresolved(directory: directory) else { throw RestoreDirectory.failure() }
            } else {
                guard try !unresolved(directory: directory) else { throw RestoreDirectory.failure() }
            }
        }
    }
    static func unresolved(directory: RestoreDirectory) throws -> Bool {
        let review = BackupManifest.digest(try directory.read("plan.json", maximum: 65536))
        return try load(directory, review: review).phase.unresolved
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try encoder.encode(value)
    }
}

final class RestoreJournalStorage {
    let root: RestoreDirectory
    let operation: RestoreDirectory?
    private let lockHandle: FileHandle
    private var lock: Int32 { lockHandle.fileDescriptor }
    private let synchronize: @Sendable (Int32) -> Int32
    init(root: URL, operation: URL? = nil, synchronize: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }) throws {
        self.root = try RestoreDirectory(root)
        self.synchronize = synchronize
        let lock = openat(self.root.fd, ".stock-restore.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw RestoreDirectory.failure() }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              fchmod(lock, 0o600) == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw RestoreDirectory.failure() }
        self.lockHandle = FileHandle(fileDescriptor:lock,closeOnDealloc:true)
        do {
            self.operation = try operation.map { try RestoreDirectory($0) }
            try checkLock()
        } catch { try? lockHandle.close(); throw error }
    }
    private var leaseClosed = false
    deinit { try? lockHandle.close() }
    func closeLease() throws {
        guard !leaseClosed else { return }
        leaseClosed = true
        guard flock(lock, LOCK_UN) == 0 else { throw RestoreDirectory.failure() }
        try lockHandle.close()
    }
    func checkLock() throws {
        guard !leaseClosed else { throw RestoreDirectory.failure() }
        try root.check(); try operation?.check()
        var held = stat(), named = stat()
        guard fstat(lock, &held) == 0, fstatat(root.fd, ".stock-restore.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw RestoreDirectory.failure() }
    }
    func sync(_ directory: RestoreDirectory) throws {
        try checkLock(); try directory.check()
        guard synchronize(directory.fd) == 0 else { throw RestoreDirectory.failure() }
        try checkLock(); try directory.check()
    }
    func write(_ data: Data, name: String, directory: RestoreDirectory) throws {
        try Task.checkCancellation(); try checkLock(); try directory.check()
        let fd = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw RestoreDirectory.failure() }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw RestoreDirectory.failure() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RestoreDirectory.failure() }
                offset += count
            }
        }
        guard synchronize(fd) == 0 else { throw RestoreDirectory.failure() }
        guard try directory.read(name, maximum: max(1, data.count)) == data else { throw RestoreDirectory.failure() }
        try checkLock(); try directory.check()
    }
}
