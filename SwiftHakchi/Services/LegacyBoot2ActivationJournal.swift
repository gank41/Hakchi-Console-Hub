import Foundation
import Darwin
import SwiftHakchiCore

actor LegacyBoot2ActivationJournal {
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
    static func prepare(material: LegacyBoot2ActivationMaterial, root: URL) throws -> Prepared {
        try Task.checkCancellation()
        try material.validateIntegrity()
        let storage = try RestoreJournalStorage(root: root)
        try checkOthers(storage, excluding: nil)
        let name = "LegacyBoot2Activation-" + material.plan.id.uuidString
        guard mkdirat(storage.root.fd, name, 0o700) == 0 else { throw RestoreDirectory.failure() }
        let operation = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
        guard fchmod(operation.fd, 0o700) == 0 else { throw RestoreDirectory.failure() }
        try storage.write(material.stock, name: "stock.img", directory: operation)
        try storage.write(material.legacy, name: "legacy.img", directory: operation)
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
    func verifiedMaterial() throws -> LegacyBoot2ActivationMaterial {
        let data = try state().material
        try data.validateIntegrity()
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
        let phase: Phase; let count: Int; let lastSHA: String; let material: LegacyBoot2ActivationMaterial
    }
    private static func load(_ directory: RestoreDirectory, review: String) throws -> State {
        let planData = try directory.read("plan.json", maximum: 65536)
        guard BackupManifest.digest(planData) == review else { throw RestoreDirectory.failure() }
        let plan = try JSONDecoder().decode(LegacyBoot2ActivationPlan.self, from: planData)
        guard directory.url.lastPathComponent == "LegacyBoot2Activation-" + plan.id.uuidString else { throw RestoreDirectory.failure() }
        let material = try LegacyBoot2ActivationMaterial(plan: plan, stock: directory.read("stock.img"), legacy: directory.read("legacy.img"))
        try material.validateIntegrity()
        let names = try directory.names()
        let events = names.filter { $0 != "plan.json" && $0 != "stock.img" && $0 != "legacy.img" }
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
            ($0.hasPrefix("LegacyBoot2Activation-") || $0.hasPrefix("StockKernelRestore-")) && $0 != excluding
        }
        guard names.count <= 64 else { throw RestoreDirectory.failure() }
        for name in names {
            let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
            if name.hasPrefix("StockKernelRestore-") {
                guard try !StockRestoreJournal.unresolved(directory: directory) else { throw RestoreDirectory.failure() }
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

