import Foundation

/// Read-only image evidence; matching metadata is not proof of console
/// identity, quiescent writers or authority to change a console.
enum SNESRetainedImageObservation {
    static func capture(managerRecord: Data, request: SNESCompatibilityLaunchRequest, expectedManagerSavePath: String?,
                        expectedManagerImagePath: String, expectedSHA256: String,
                        validate: @Sendable () async throws -> Void, read: @Sendable () async throws -> Data) async throws -> Data {
        try await validate(); let first = try await read()
        guard first.count <= 8 * 1024 * 1024 + 24576 else { throw SNESLibraryMenu.failure() }
        try await validate(); let second = try await read(); try await validate()
        guard first == second else { throw SNESLibraryMenu.failure() }
        let result = try parse(second, managerRecord: managerRecord, request: request, expectedManagerSavePath: expectedManagerSavePath,
                               expectedManagerImagePath: expectedManagerImagePath, expectedSHA256: expectedSHA256)
        // Parsing and image decoding can take time while the connection
        // changes. Recheck its generation before returning this observation.
        try await validate()
        try request.verifySource()
        return result
    }
    static func parse(_ raw: Data, managerRecord: Data, request: SNESCompatibilityLaunchRequest,
                      expectedManagerSavePath: String?, expectedManagerImagePath: String, expectedSHA256: String) throws -> Data {
        let failure = SNESLibraryMenu.failure()
        guard raw.count <= 8 * 1024 * 1024 + 24576, request.frame.count == 107 else { throw failure }
        let bytes = [UInt8](raw), prefix = Array("HC-RETAINED-IMAGE-1\n".utf8), footer = Array("HC-RETAINED-IMAGE-END\n".utf8)
        guard bytes.starts(with: prefix), let end = bytes[prefix.count...].firstIndex(of: 10), end - prefix.count <= 120,
              let header = String(bytes: bytes[prefix.count..<end], encoding: .ascii) else { throw failure }
        let fields = header.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 5, let device = UInt64(fields[0]), String(device) == fields[0],
              let inode = UInt64(fields[1]), inode > 0, String(inode) == fields[1],
              let descriptorLength = Int(fields[2]), (1..<20000).contains(descriptorLength), String(descriptorLength) == fields[2],
              let entryCount = Int(fields[3]), (1...16).contains(entryCount), String(entryCount) == fields[3],
              let imageLength = Int(fields[4]), (1...8*1024*1024).contains(imageLength), String(imageLength) == fields[4] else { throw failure }
        var position = end + 1
        guard descriptorLength <= bytes.count - position else { throw failure }
        let descriptor = Data(bytes[position..<(position + descriptorLength)]); position += descriptorLength
        let frame = request.frame, gameCode = String(decoding: frame[8..<19], as: UTF8.self)
        let token = frame[83..<99].map { String(format: "%02x", $0) }.joined()
        let stateName = "state-\(token).state", imageName = "shot-\(token).png"
        var allowed = Set(["battery.srm", "battery.rtc", imageName])
        if expectedManagerSavePath != nil { allowed.insert(stateName) }
        var seen = Set<String>(), matchedImage = 0
        for _ in 0..<entryCount {
            guard position < bytes.count, let lineEnd = bytes[position...].firstIndex(of: 10), lineEnd - position <= 255,
                  let line = String(bytes: bytes[position..<lineEnd], encoding: .ascii) else { throw failure }
            position = lineEnd + 1
            let entry = line.split(separator: " ", omittingEmptySubsequences: false)
            guard entry.count == 6, entry[0] == "ENTRY", entry[1] == token,
                  entry[2].hasPrefix("checkpoint-"), entry[2].utf8.count == 43,
                  entry[2].dropFirst(11).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  seen.insert(String(entry[2])).inserted, allowed.contains(String(entry[3])),
                  entry[4] == "1" || entry[4] == "2", entry[5] == "0" || entry[5] == "1" else { throw failure }
            if entry[3] == imageName { guard entry[4] == "2", entry[5] == "1" else { throw failure }; matchedImage += 1 }
        }
        guard matchedImage == 1, imageLength <= bytes.count - position,
              bytes.count - position - imageLength == footer.count,
              bytes.suffix(footer.count).elementsEqual(footer) else { throw failure }
        let payload = Data(bytes[position..<(position + imageLength)])
        let base = "/var/lib/clover/profiles/0/\(gameCode)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        var regions = [SNESRecoveryBinding.Region(path: base + "/battery.srm", type: 0, device: device, inode: inode),
                       SNESRecoveryBinding.Region(path: base + "/battery.rtc", type: 1, device: device, inode: inode)]
        if expectedManagerSavePath != nil { regions.append(.init(path: base + "/" + stateName, type: 101, device: device, inode: inode)) }
        regions.append(.init(path: base + "/" + imageName, type: 100, device: device, inode: inode))
        return try SNESRecoveryBinding.validateSessionRetainedScreenshot(descriptor: descriptor, managerRecord: managerRecord,
            request: request, regions: regions, expectedManagerSavePath: expectedManagerSavePath,
            expectedManagerImagePath: expectedManagerImagePath, image: payload, expectedSHA256: expectedSHA256)
    }
}

/// Bounded read-only retained-state evidence. It does not establish console
/// identity or writer exclusion and never authorizes restoration by itself.
enum SNESRetainedStateObservation {
    static func capture(managerRecord: Data, request: SNESCompatibilityLaunchRequest, game: Game,
                        expectedManagerSavePath: String, expectedManagerImagePath: String?, expectedSHA256: String,
                        validate: @Sendable () async throws -> Void,
                        read: @Sendable () async throws -> Data) async throws -> SNESCompatibilitySave {
        try await validate(); let first = try await read()
        guard first.count <= 16 * 1024 * 1024 + 24576 else { throw SNESLibraryMenu.failure() }
        try await validate(); let second = try await read(); try await validate()
        guard first == second else { throw SNESLibraryMenu.failure() }
        let result = try parse(second, managerRecord: managerRecord, request: request, game: game,
                               expectedManagerSavePath: expectedManagerSavePath, expectedManagerImagePath: expectedManagerImagePath,
                               expectedSHA256: expectedSHA256)
        try await validate()
        try request.verifySource()
        return result
    }
    static func parse(_ raw: Data, managerRecord: Data, request: SNESCompatibilityLaunchRequest, game: Game,
                      expectedManagerSavePath: String, expectedManagerImagePath: String?,
                      expectedSHA256: String) throws -> SNESCompatibilitySave {
        let failure = SNESLibraryMenu.failure()
        guard raw.count <= 16 * 1024 * 1024 + 24576, request.frame.count == 107 else { throw failure }
        let bytes = [UInt8](raw), prefix = Array("HC-RETAINED-STATE-1\n".utf8), footer = Array("HC-RETAINED-STATE-END\n".utf8)
        guard bytes.starts(with: prefix), let end = bytes[prefix.count...].firstIndex(of: 10), end - prefix.count <= 120,
              let header = String(bytes: bytes[prefix.count..<end], encoding: .ascii) else { throw failure }
        let fields = header.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 5, let device = UInt64(fields[0]), String(device) == fields[0],
              let inode = UInt64(fields[1]), inode > 0, String(inode) == fields[1],
              let descriptorLength = Int(fields[2]), (1..<20000).contains(descriptorLength), String(descriptorLength) == fields[2],
              let entryCount = Int(fields[3]), (1...16).contains(entryCount), String(entryCount) == fields[3],
              let stateLength = Int(fields[4]), (1...16*1024*1024).contains(stateLength), String(stateLength) == fields[4] else { throw failure }
        var position = end + 1
        guard descriptorLength <= bytes.count - position else { throw failure }
        let descriptor = Data(bytes[position..<(position + descriptorLength)]); position += descriptorLength
        let frame = request.frame, gameCode = String(decoding: frame[8..<19], as: UTF8.self)
        let token = frame[83..<99].map { String(format: "%02x", $0) }.joined()
        let stateName = "state-\(token).state", imageName = "shot-\(token).png"
        var allowed = Set(["battery.srm", "battery.rtc", stateName])
        if expectedManagerImagePath != nil { allowed.insert(imageName) }
        var seen = Set<String>(), matchedState = 0
        for _ in 0..<entryCount {
            guard position < bytes.count, let lineEnd = bytes[position...].firstIndex(of: 10), lineEnd - position <= 255,
                  let line = String(bytes: bytes[position..<lineEnd], encoding: .ascii) else { throw failure }
            position = lineEnd + 1
            let entry = line.split(separator: " ", omittingEmptySubsequences: false)
            guard entry.count == 6, entry[0] == "ENTRY", entry[1] == token,
                  entry[2].hasPrefix("checkpoint-"), entry[2].utf8.count == 43,
                  entry[2].dropFirst(11).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  seen.insert(String(entry[2])).inserted, allowed.contains(String(entry[3])),
                  entry[4] == "1" || entry[4] == "2", entry[5] == "0" || entry[5] == "1" else { throw failure }
            if entry[3] == stateName { guard entry[4] == "2", entry[5] == "1" else { throw failure }; matchedState += 1 }
        }
        guard matchedState == 1, stateLength <= bytes.count - position,
              bytes.count - position - stateLength == footer.count,
              bytes.suffix(footer.count).elementsEqual(footer) else { throw failure }
        let payload = Data(bytes[position..<(position + stateLength)])
        let base = "/var/lib/clover/profiles/0/\(gameCode)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        var regions = [SNESRecoveryBinding.Region(path: base + "/battery.srm", type: 0, device: device, inode: inode),
                       SNESRecoveryBinding.Region(path: base + "/battery.rtc", type: 1, device: device, inode: inode),
                       SNESRecoveryBinding.Region(path: base + "/" + stateName, type: 101, device: device, inode: inode)]
        if expectedManagerImagePath != nil { regions.append(.init(path: base + "/" + imageName, type: 100, device: device, inode: inode)) }
        return try SNESRecoveryBinding.validateSessionRetainedState(descriptor: descriptor, managerRecord: managerRecord,
            request: request, game: game, regions: regions, expectedManagerSavePath: expectedManagerSavePath,
            expectedManagerImagePath: expectedManagerImagePath, state: payload, expectedSHA256: expectedSHA256)
    }
}
import Darwin
import SwiftHakchiCore

/// A small durable correlation record in a user-selected Mac folder. It
/// contains no ROM or save payload. It is not authentication, a console
/// observation, or permission to launch, restore or delete anything. The
/// caller must authenticate the pre-launch inventory and exclusively control
/// the destination while creating or reopening it. A post-crash inventory may
/// differ because recovery files were created; this is not a restart coordinator.
struct SNESCompatibilityRecoveryReference: Sendable {
    let directory: URL, recordSHA256: String, evidence: SNESCompatibilityBackupEvidence
    private struct Record: Codable, Equatable {
        let version: Int, gameCode: String, romSHA256: String, session: String, epoch: UInt64
        let backupManifestSHA256: String, snapshotSHA256: String
        let originalKind: String, originalByteCount: Int, originalSHA256: String?
    }
    private static func failure() -> RecoveryProbeError {
        .refused("The saved compatibility session could not be verified. The console has not been changed.")
    }
    private static func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }
    private static func record(_ evidence: SNESCompatibilityBackupEvidence) -> Record {
        let kind: String, count: Int, digest: String?
        switch evidence.original {
        case .absent: kind = "absent"; count = 0; digest = nil
        case .present(let bytes): kind = "present"; count = bytes.count; digest = BackupManifest.digest(bytes)
        }
        return Record(version: 1, gameCode: evidence.gameCode, romSHA256: evidence.romSHA256,
                      session: evidence.session.map { String(format: "%02x", $0) }.joined(), epoch: evidence.epoch,
                      backupManifestSHA256: evidence.backupManifestSHA256, snapshotSHA256: evidence.snapshotSHA256,
                      originalKind: kind, originalByteCount: count, originalSHA256: digest)
    }
    private static func leaf(_ value: Record) -> String {
        "SNES-Compatibility-" + value.session + "-" + String(value.epoch)
    }
    static func plannedName(for evidence: SNESCompatibilityBackupEvidence) -> String {
        leaf(record(evidence))
    }
    private static func privateDirectory(_ directory: RestoreDirectory) throws {
        try directory.check(); var info = stat()
        guard fstat(directory.fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw failure() }
    }
    private static func checkEntries(_ directory: RestoreDirectory) throws {
        var names = Set(try directory.names())
        if names.remove(".DS_Store") != nil {
            var info = stat()
            guard fstatat(directory.fd, ".DS_Store", &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  (0...1_048_576).contains(info.st_size) else { throw failure() }
        }
        guard names == ["record.json"] else { throw failure() }
    }
    static func create(root: URL, backup: SNESLibraryBackup, current: SNESLibraryInventory,
                       request: SNESCompatibilityLaunchRequest) throws -> Self {
        let evidence = try SNESCompatibilityBackupEvidence.capture(backup: backup, current: current, request: request)
        let value = record(evidence), data = try encode(value), parent = try RestoreDirectory(root)
        guard data.count <= 4096 else { throw failure() }
        var info = stat()
        guard fstat(parent.fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw failure() }
        let name = leaf(value)
        guard mkdirat(parent.fd, name, 0o700) == 0, fsync(parent.fd) == 0 else { throw failure() }
        let directory = try RestoreDirectory(parent.url.appendingPathComponent(name, isDirectory: true))
        try privateDirectory(directory); try parent.check()
        let fd = openat(directory.fd, "record.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure() }
        var descriptorOpen = true
        defer { if descriptorOpen { _ = Darwin.close(fd) } }
        guard fchmod(fd, 0o600) == 0 else { throw failure() }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try Task.checkCancellation()
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw failure() }; offset += n
            }
        }
        guard fsync(fd) == 0, Darwin.close(fd) == 0 else { throw failure() }
        descriptorOpen = false
        guard fsync(directory.fd) == 0 else { throw failure() }
        try checkEntries(directory); try evidence.validate(request: request); try parent.check()
        guard try directory.read("record.json", maximum: 4096) == data else { throw failure() }
        return Self(directory: directory.url, recordSHA256: BackupManifest.digest(data), evidence: evidence)
    }
    static func open(directory url: URL, backup: SNESLibraryBackup, current: SNESLibraryInventory,
                     request: SNESCompatibilityLaunchRequest) throws -> Self {
        let evidence = try SNESCompatibilityBackupEvidence.capture(backup: backup, current: current, request: request)
        return try openVerified(directory: url, evidence: evidence, request: request)
    }
    /// Reopens only the historical Mac backup evidence after an interruption.
    /// This neither observes nor authenticates the connected console or its
    /// current session, and never authorizes recovery or any console write.
    static func openHistorical(directory url: URL, backup: SNESLibraryBackup,
                               request: SNESCompatibilityLaunchRequest) throws -> Self {
        let evidence = try SNESCompatibilityBackupEvidence.capture(backup: backup, current: backup.inventory, request: request)
        return try openVerified(directory: url, evidence: evidence, request: request)
    }
    /// Match a reopened historical Mac reference to one supplied console binding.
    /// This is read-only: the caller must authenticate the live observation,
    /// establish exclusive access and stop writers before any recovery action.
    static func matchHistoricalBinding(directory: URL, backup: SNESLibraryBackup,
                                       request: SNESCompatibilityLaunchRequest, descriptor: Data,
                                       region: SNESRecoveryBinding.Region) throws -> SNESCompatibilityBackupEvidence.Original {
        let reference = try openHistorical(directory: directory, backup: backup, request: request)
        let original = try SNESRecoveryBinding.validateBackupEvidence(descriptor: descriptor, evidence: reference.evidence,
                                                                       request: request, region: region)
        let rechecked = try openHistorical(directory: directory, backup: backup, request: request)
        guard rechecked.recordSHA256 == reference.recordSHA256, rechecked.evidence.original == original else { throw failure() }
        return original
    }
    /// Read-only comparison for the frontend's SRAM and RTC binding. The
    /// returned evidence covers SRAM only; the caller must independently
    /// authenticate the live observation and stop writers before recovery.
    static func matchHistoricalBinding(directory: URL, backup: SNESLibraryBackup,
                                       request: SNESCompatibilityLaunchRequest, descriptor: Data,
                                       regions: [SNESRecoveryBinding.Region]) throws -> SNESCompatibilityBackupEvidence.Original {
        let reference = try openHistorical(directory: directory, backup: backup, request: request)
        let original = try SNESRecoveryBinding.validateBackupEvidence(descriptor: descriptor, evidence: reference.evidence,
                                                                       request: request, regions: regions)
        let rechecked = try openHistorical(directory: directory, backup: backup, request: request)
        guard rechecked.recordSHA256 == reference.recordSHA256, rechecked.evidence.original == original else { throw failure() }
        return original
    }
    /// Match the complete two-region binding to independently backed-up
    /// battery and clock evidence. This is read-only and grants no recovery.
    static func matchHistoricalSaves(directory: URL, backup: SNESLibraryBackup,
                                     request: SNESCompatibilityLaunchRequest, descriptor: Data,
                                     regions: [SNESRecoveryBinding.Region]) throws -> SNESCompatibilityBackupEvidence.SavePair {
        let reference = try openHistorical(directory: directory, backup: backup, request: request)
        let battery = try SNESRecoveryBinding.validateBackupEvidence(descriptor: descriptor, evidence: reference.evidence,
                                                                      request: request, regions: regions)
        let clock = reference.evidence.clockOriginal
        let rechecked = try openHistorical(directory: directory, backup: backup, request: request)
        guard rechecked.recordSHA256 == reference.recordSHA256, rechecked.evidence.original == battery,
              rechecked.evidence.clockOriginal == clock else { throw failure() }
        return .init(battery: battery, clock: clock)
    }
    private static func openVerified(directory url: URL, evidence: SNESCompatibilityBackupEvidence,
                                     request: SNESCompatibilityLaunchRequest) throws -> Self {
        let expected = record(evidence), directory = try RestoreDirectory(url)
        try privateDirectory(directory); try checkEntries(directory)
        guard directory.url.lastPathComponent == leaf(expected) else { throw failure() }
        let data = try directory.read("record.json", maximum: 4096)
        var info = stat()
        guard fstatat(directory.fd, "record.json", &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
              data == (try encode(expected)) else { throw failure() }
        try evidence.validate(request: request); try directory.check()
        return Self(directory: directory.url, recordSHA256: BackupManifest.digest(data), evidence: evidence)
    }
}

/// Parsed read-only correlation evidence. A valid frame is not proof that a
/// console or session is authentic, that writers have stopped, or that any
/// restore/delete action is safe. The caller must establish those separately.
struct SNESRecoveryConsoleObservation: Equatable, Sendable {
    struct Pending: Equatable, Sendable { let workspace: String, region: String, kind: Int, workspacePresent: Bool }
    let device: UInt64, inode: UInt64, requestFrame: Data
    let saves: SNESCompatibilityBackupEvidence.SavePair, pending: [Pending]
    private static func failure() -> RecoveryProbeError {
        .refused("The console recovery information could not be verified. No saves were changed.")
    }
    private static func lowerHex(_ s: Substring, count: Int) -> Bool {
        s.utf8.count == count && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func parse(_ raw: Data, directory: URL, backup: SNESLibraryBackup,
                      request: SNESCompatibilityLaunchRequest) throws -> Self {
        guard raw.count <= 24576, request.frame.count == 107 else { throw failure() }
        let bytes = [UInt8](raw), prefix = Array("HC-RECOVERY-OBS-1\n".utf8)
        guard bytes.starts(with: prefix), let end = bytes[prefix.count...].firstIndex(of: 10), end - prefix.count <= 100,
              let header = String(bytes: bytes[prefix.count..<end], encoding: .ascii) else { throw failure() }
        let fields = header.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 4, let device = UInt64(fields[0]), String(device) == fields[0],
              let inode = UInt64(fields[1]), inode > 0, String(inode) == fields[1],
              let length = Int(fields[2]), (1..<20000).contains(length), String(length) == fields[2],
              let count = Int(fields[3]), (0...16).contains(count), String(count) == fields[3],
              end + 1 + length <= bytes.count else { throw failure() }
        let offset = end + 1, descriptor = Data(bytes[offset..<(offset + length)])
        guard let tail = String(bytes: bytes[(offset + length)...], encoding: .ascii) else { throw failure() }
        let lines = tail.components(separatedBy: "\n")
        guard lines.count == count + 2, lines[count] == "HC-RECOVERY-OBS-END", lines[count + 1].isEmpty else { throw failure() }
        let token = request.frame[83..<99].map { String(format: "%02x", $0) }.joined()
        var pending: [Pending] = [], seen = Set<String>()
        for line in lines.prefix(count) {
            let item = line.split(separator: " ", omittingEmptySubsequences: false)
            guard item.count == 6, item[0] == "ENTRY", item[1] == token,
                  item[2].hasPrefix("checkpoint-"), lowerHex(item[2].dropFirst(11), count: 32),
                  ["battery.srm", "battery.rtc"].contains(String(item[3])),
                  let kind = Int(item[4]), [1, 2].contains(kind), String(kind) == item[4],
                  item[5] == "0" || item[5] == "1", seen.insert(String(item[2])).inserted else { throw failure() }
            pending.append(.init(workspace: String(item[2]), region: String(item[3]), kind: kind, workspacePresent: item[5] == "1"))
        }
        let base = "/var/lib/clover/profiles/0/\(String(decoding: request.frame[8..<19], as: UTF8.self))/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        let regions = [SNESRecoveryBinding.Region(path: base + "/battery.srm", type: 0, device: device, inode: inode),
                       SNESRecoveryBinding.Region(path: base + "/battery.rtc", type: 1, device: device, inode: inode)]
        let saves = try SNESCompatibilityRecoveryReference.matchHistoricalSaves(directory: directory, backup: backup,
                                                                                 request: request, descriptor: descriptor, regions: regions)
        return .init(device: device, inode: inode, requestFrame: request.frame, saves: saves, pending: pending)
    }
}

/// Repeated read-only observations for a checked connection. Identical frames
/// do not authenticate the console or establish that save writers stopped.
struct SNESCompatibilityRecoveryCapture {
    static func read(directory: URL, backup: SNESLibraryBackup, request: SNESCompatibilityLaunchRequest,
                     validate: @Sendable () async throws -> Void,
                     read: @Sendable () async throws -> Data) async throws -> SNESRecoveryConsoleObservation {
        try await validate()
        let first = try await read()
        guard first.count <= 24576 else { throw SNESCompatibilitySupportFrame.failure() }
        try await validate()
        let second = try await read()
        try await validate()
        guard second.count <= 24576, first == second else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try SNESRecoveryConsoleObservation.parse(second, directory: directory, backup: backup, request: request)
        try await validate()
        return result
    }
    static func readCurrent(observation: SNESRecoveryConsoleObservation, request: SNESCompatibilityLaunchRequest,
                            region: SNESRecoveryRegion, validate: @Sendable () async throws -> Void,
                            read: @Sendable () async throws -> Data) async throws -> SNESRecoveryCurrentSave {
        guard observation.requestFrame == request.frame else { throw SNESCompatibilitySupportFrame.failure() }
        try request.verifySource(); try await validate()
        let first = try await read()
        guard first.count <= 128 * 1024 + 256 else { throw SNESCompatibilitySupportFrame.failure() }
        try await validate()
        let second = try await read()
        try await validate()
        guard second.count <= 128 * 1024 + 256, first == second else { throw SNESCompatibilitySupportFrame.failure() }
        let result = try SNESRecoveryCurrentSave.parse(second, observation: observation, region: region)
        try request.verifySource(); try await validate()
        return result
    }
}

/// Bounded current bytes from the experimental collector. The same parent
/// identity is correlation only; callers must authenticate the attachment and
/// establish stopped writers and exclusive access before using these bytes.
enum SNESRecoveryRegion: String, Sendable { case battery = "sram", clock = "rtc" }

enum SNESRecoveryCurrentSave: Equatable, Sendable {
    case absent, present(Data)
    static func parse(_ raw: Data, observation: SNESRecoveryConsoleObservation, region: SNESRecoveryRegion) throws -> Self {
        func failure() -> RecoveryProbeError { .refused("The current console save could not be checked. No saves were changed.") }
        let prefix = Array("HC-RECOVERY-CURRENT-1\n".utf8), footer = Array("HC-RECOVERY-CURRENT-END\n".utf8), bytes = [UInt8](raw)
        guard bytes.count <= 128 * 1024 + 256, bytes.starts(with: prefix),
              let end = bytes[prefix.count...].firstIndex(of: 10), end - prefix.count <= 100,
              let header = String(bytes: bytes[prefix.count..<end], encoding: .ascii) else { throw failure() }
        let fields = header.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 5, let device = UInt64(fields[0]), String(device) == fields[0], device == observation.device,
              let inode = UInt64(fields[1]), String(inode) == fields[1], inode == observation.inode,
              fields[2] == region.rawValue, let present = Int(fields[3]), [0, 1].contains(present), String(present) == fields[3],
              let length = Int(fields[4]), (0...128 * 1024).contains(length), String(length) == fields[4],
              (present == 0 && length == 0) || (present == 1 && length > 0) else { throw failure() }
        let start = end + 1, finish = start + length
        guard finish <= bytes.count, Array(bytes[finish...]) == footer else { throw failure() }
        return present == 0 ? .absent : .present(Data(bytes[start..<finish]))
    }
}

struct SNESRecoveryCurrentCapture: Sendable {
    let observation: SNESRecoveryConsoleObservation, current: SNESRecoveryCurrentSave
}

/// Durable Mac copy of a current-save observation. This record is untrusted
/// correlation evidence, not proof of a unique console or stopped writers,
/// and never authorizes console restoration or deletion.
struct SNESCompatibilityCurrentEvidence: Sendable {
    let directory: URL, current: SNESRecoveryCurrentSave
    private struct Pending: Codable, Equatable {
        let workspace: String, region: String, kind: Int, workspacePresent: Bool
    }
    private struct Record: Codable, Equatable {
        let version: Int, referenceSHA256: String, backupSHA256: String, requestSHA256: String
        let device: UInt64, inode: UInt64, region: String, pending: [Pending]
        let present: Bool, byteCount: Int, payloadSHA256: String?
    }
    private static func failure() -> RecoveryProbeError {
        .refused("The saved recovery information could not be verified. No console saves were changed.")
    }
    private static func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }
    private static func reference(directory: URL, backup: SNESLibraryBackup, request: SNESCompatibilityLaunchRequest,
                                  observation: SNESRecoveryConsoleObservation) throws -> SNESCompatibilityRecoveryReference {
        let ref = try SNESCompatibilityRecoveryReference.openHistorical(directory: directory, backup: backup, request: request)
        guard observation.requestFrame == request.frame, observation.saves.battery == ref.evidence.original,
              observation.saves.clock == ref.evidence.clockOriginal else { throw failure() }
        return ref
    }
    private static func record(ref: SNESCompatibilityRecoveryReference, request: SNESCompatibilityLaunchRequest,
                               observation: SNESRecoveryConsoleObservation, region: SNESRecoveryRegion,
                               current: SNESRecoveryCurrentSave) throws -> Record {
        let present: Bool, bytes: Data
        switch current { case .absent: present = false; bytes = Data(); case .present(let data): present = true; bytes = data }
        guard !present || (1...128 * 1024).contains(bytes.count) else { throw failure() }
        return .init(version: 1, referenceSHA256: ref.recordSHA256, backupSHA256: ref.evidence.backupManifestSHA256,
                     requestSHA256: BackupManifest.digest(request.frame), device: observation.device, inode: observation.inode,
                     region: region.rawValue, pending: observation.pending.map { .init(workspace: $0.workspace, region: $0.region, kind: $0.kind, workspacePresent: $0.workspacePresent) },
                     present: present, byteCount: bytes.count, payloadSHA256: present ? BackupManifest.digest(bytes) : nil)
    }
    private static func leaf(_ ref: SNESCompatibilityRecoveryReference, region: SNESRecoveryRegion) -> String {
        let token = ref.evidence.session.map { String(format: "%02x", $0) }.joined()
        return "SNES-Current-" + token + "-" + String(ref.evidence.epoch) + "-" + region.rawValue
    }
    private static func checkPrivate(_ dir: RestoreDirectory) throws {
        try dir.check(); var st = stat()
        guard fstat(dir.fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFDIR, st.st_mode & 0o777 == 0o700 else { throw failure() }
    }
    private static func writeExclusive(_ data: Data, name: String, directory: RestoreDirectory) throws {
        let fd = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure() }
        var isOpen = true; defer { if isOpen { _ = Darwin.close(fd) } }
        guard fchmod(fd, 0o600) == 0 else { throw failure() }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try Task.checkCancellation()
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw failure() }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw failure() }
        let status = Darwin.close(fd); isOpen = false
        guard status == 0 else { throw failure() }
    }
    static func create(root: URL, referenceDirectory: URL, backup: SNESLibraryBackup, request: SNESCompatibilityLaunchRequest,
                       observation: SNESRecoveryConsoleObservation, region: SNESRecoveryRegion, current: SNESRecoveryCurrentSave,
                       afterPayloadWritten: () throws -> Void = {}) throws -> Self {
        let ref = try reference(directory: referenceDirectory, backup: backup, request: request, observation: observation)
        let meta = try record(ref: ref, request: request, observation: observation, region: region, current: current)
        let parent = try RestoreDirectory(root); var st = stat()
        guard fstat(parent.fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o022 == 0 else { throw failure() }
        let name = leaf(ref, region: region)
        let stage = ".SNES-Current-" + UUID().uuidString
        guard mkdirat(parent.fd, stage, 0o700) == 0, fsync(parent.fd) == 0 else { throw failure() }
        let directory = try RestoreDirectory(parent.url.appendingPathComponent(stage, isDirectory: true)); try checkPrivate(directory)
        if case .present(let bytes) = current { try writeExclusive(bytes, name: "current.bin", directory: directory) }
        try afterPayloadWritten()
        try writeExclusive(try encode(meta), name: "record.json", directory: directory)
        guard fsync(directory.fd) == 0 else { throw failure() }
        try directory.check(); try parent.check(); try Task.checkCancellation()
        guard renameatx_np(parent.fd, stage, parent.fd, name, UInt32(RENAME_EXCL)) == 0, fsync(parent.fd) == 0 else { throw failure() }
        var held = stat(), published = stat()
        guard fstat(directory.fd, &held) == 0, fstatat(parent.fd, name, &published, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == published.st_dev, held.st_ino == published.st_ino,
              published.st_mode & S_IFMT == S_IFDIR, published.st_uid == getuid(), published.st_mode & 0o777 == 0o700 else { throw failure() }
        try parent.check()
        return try open(directory: parent.url.appendingPathComponent(name, isDirectory: true), referenceDirectory: referenceDirectory, backup: backup, request: request, observation: observation, region: region)
    }
    static func createOrResume(root: URL, referenceDirectory: URL, backup: SNESLibraryBackup, request: SNESCompatibilityLaunchRequest,
                               observation: SNESRecoveryConsoleObservation, region: SNESRecoveryRegion, current: SNESRecoveryCurrentSave) throws -> Self {
        try Task.checkCancellation()
        let ref = try reference(directory: referenceDirectory, backup: backup, request: request, observation: observation)
        let parent = try RestoreDirectory(root); var parentInfo = stat(), found = stat()
        guard fstat(parent.fd, &parentInfo) == 0, parentInfo.st_uid == getuid(), parentInfo.st_mode & 0o022 == 0 else { throw failure() }
        let name = leaf(ref, region: region), url = parent.url.appendingPathComponent(name, isDirectory: true)
        if fstatat(parent.fd, name, &found, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw failure() }
            try parent.check()
            return try create(root: root, referenceDirectory: referenceDirectory, backup: backup, request: request, observation: observation, region: region, current: current)
        }
        let existing = try open(directory: url, referenceDirectory: referenceDirectory, backup: backup, request: request, observation: observation, region: region)
        guard existing.current == current else { throw failure() }
        let dir = try RestoreDirectory(url); try checkPrivate(dir)
        guard fstat(dir.fd, &parentInfo) == 0, parentInfo.st_dev == found.st_dev, parentInfo.st_ino == found.st_ino else { throw failure() }
        for name in (current == .absent ? ["record.json"] : ["current.bin", "record.json"]) {
            let fd = openat(dir.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw failure() }
            var info = stat()
            let valid = fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o777 == 0o600 && fsync(fd) == 0
            let closed = Darwin.close(fd) == 0
            guard valid && closed else { throw failure() }
        }
        guard fsync(dir.fd) == 0, fsync(parent.fd) == 0 else { throw failure() }
        try dir.check(); try parent.check(); try Task.checkCancellation()
        let checked = try open(directory: url, referenceDirectory: referenceDirectory, backup: backup, request: request, observation: observation, region: region)
        guard checked.current == current else { throw failure() }
        return checked
    }
    static func open(directory url: URL, referenceDirectory: URL, backup: SNESLibraryBackup, request: SNESCompatibilityLaunchRequest,
                     observation: SNESRecoveryConsoleObservation, region: SNESRecoveryRegion) throws -> Self {
        let ref = try reference(directory: referenceDirectory, backup: backup, request: request, observation: observation)
        let dir = try RestoreDirectory(url); try checkPrivate(dir)
        guard dir.url.lastPathComponent == leaf(ref, region: region) else { throw failure() }
        let raw = try dir.read("record.json", maximum: 8192), stored = try JSONDecoder().decode(Record.self, from: raw)
        guard raw == (try encode(stored)), stored.version == 1 else { throw failure() }
        let allowed = stored.present ? Set(["record.json", "current.bin"]) : Set(["record.json"])
        guard Set(try dir.names()) == allowed else { throw failure() }
        var current: SNESRecoveryCurrentSave = .absent
        if stored.present {
            let payload = try dir.read("current.bin", maximum: 128 * 1024)
            guard !payload.isEmpty else { throw failure() }; current = .present(payload)
        }
        for name in allowed {
            var st = stat()
            guard fstatat(dir.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG,
                  st.st_uid == getuid(), st.st_nlink == 1, st.st_mode & 0o777 == 0o600 else { throw failure() }
        }
        guard stored == (try record(ref: ref, request: request, observation: observation, region: region, current: current)) else { throw failure() }
        try ref.evidence.validate(request: request); try dir.check()
        return .init(directory: dir.url, current: current)
    }
}

/// Read-only description of one clock recovery. The caller must independently
/// authenticate the live console and exact session, stop all writers, retain
/// exclusive access and separately approve any operation that changes files.
/// Offline correlation only. The caller must authenticate the console, stop
/// writers, control the paths and separately approve any restore operation.
private func appendRecoveryCurrent(_ current: SNESRecoveryCurrentSave, to frame: inout Data) throws {
    let bytes: Data
    switch current {
    case .absent: frame.append(0); bytes = Data()
    case .present(let data):
        guard (1...128 * 1024).contains(data.count) else { throw SNESCompatibilitySupportFrame.failure() }
        frame.append(1); bytes = data
    }
    let count = UInt32(bytes.count)
    for offset in 0..<4 { frame.append(UInt8(truncatingIfNeeded: count >> (offset * 8))) }
    frame.append(bytes)
}
struct SNESBatteryRecoveryPlan: Sendable {
    let workspace: String, originalPresent: Bool, evidence: Data, intentKind: Int
    private let current: SNESRecoveryCurrentSave
    private let request: SNESCompatibilityLaunchRequest
    private let referenceDirectory: URL, currentDirectory: URL, backup: SNESLibraryBackup
    private let observation: SNESRecoveryConsoleObservation
    private func validateEvidence() throws {
        let checked = try Self.prepare(referenceDirectory: referenceDirectory, currentDirectory: currentDirectory, backup: backup,
                                       request: request, observation: observation, workspace: workspace)
        guard checked.originalPresent == originalPresent, checked.evidence == evidence, checked.current == current, checked.intentKind == intentKind else { throw SNESCompatibilitySupportFrame.failure() }
    }
    /// Correlation data only; this is not authorization to change a console.
    func encodedRequest() throws -> Data {
        try request.verifySource(); try validateEvidence()
        let path = Array(workspace.utf8)
        guard request.frame.count == 107, path.count == 43,
              path.prefix(11).elementsEqual("checkpoint-".utf8),
              path.dropFirst(11).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...128 * 1024).contains(evidence.count) else { throw SNESCompatibilitySupportFrame.failure() }
        var frame = Data("HCRST30\0".utf8); frame.append(request.frame); frame.append(contentsOf: path)
        frame.append(originalPresent ? 1 : 2)
        let size = UInt32(evidence.count)
        for offset in 0..<4 { frame.append(UInt8(truncatingIfNeeded: size >> (offset * 8))) }
        frame.append(evidence)
        try appendRecoveryCurrent(current, to: &frame)
        for number in [observation.device, observation.inode] { for offset in 0..<8 { frame.append(UInt8(truncatingIfNeeded: number >> (offset * 8))) } }
        guard [1, 2].contains(intentKind) else { throw SNESCompatibilitySupportFrame.failure() }; frame.append(UInt8(intentKind))
        try validateEvidence(); try request.verifySource(); return frame
    }
    static func prepare(referenceDirectory: URL, currentDirectory: URL, backup: SNESLibraryBackup,
                        request: SNESCompatibilityLaunchRequest, observation: SNESRecoveryConsoleObservation,
                        workspace: String) throws -> Self {
        func failure() -> RecoveryProbeError { .refused("The save recovery could not be verified. No console saves were changed.") }
        let entries = observation.pending.filter { $0.workspace == workspace }
        guard entries.count == 1, let entry = entries.first, entry.region == "battery.srm", entry.workspacePresent else { throw failure() }
        let reference = try SNESCompatibilityRecoveryReference.openHistorical(directory: referenceDirectory, backup: backup, request: request)
        let retained = try SNESCompatibilityCurrentEvidence.open(directory: currentDirectory, referenceDirectory: referenceDirectory,
                                                                 backup: backup, request: request, observation: observation, region: .battery)
        let present: Bool, bytes: Data
        switch reference.evidence.original {
        case .present(let original): present = true; bytes = original
        case .absent:
            guard case .present(let current) = retained.current else { throw failure() }
            present = false; bytes = current
        }
        guard (1...128 * 1024).contains(bytes.count) else { throw failure() }
        try reference.evidence.validate(request: request)
        return .init(workspace: workspace, originalPresent: present, evidence: bytes, intentKind: entry.kind, current: retained.current, request: request,
                     referenceDirectory: referenceDirectory, currentDirectory: currentDirectory, backup: backup, observation: observation)
    }
}

struct SNESClockRecoveryPlan: Sendable {
    let workspace: String, regionIndex: Int, originalPresent: Bool, evidence: Data, intentKind: Int
    private let current: SNESRecoveryCurrentSave
    private let request: SNESCompatibilityLaunchRequest
    private let referenceDirectory: URL, currentDirectory: URL, backup: SNESLibraryBackup
    private let observation: SNESRecoveryConsoleObservation
    private func validateEvidence() throws {
        let checked = try Self.prepare(referenceDirectory: referenceDirectory, currentDirectory: currentDirectory, backup: backup,
                                       request: request, observation: observation, workspace: workspace)
        guard checked.regionIndex == regionIndex, checked.originalPresent == originalPresent, checked.evidence == evidence, checked.current == current, checked.intentKind == intentKind else { throw SNESCompatibilitySupportFrame.failure() }
    }
    /// Correlation data for a reviewed host-side recovery test. This is not
    /// authentication, stopped-writer evidence, or a write authorization.
    func encodedRequest() throws -> Data {
        try request.verifySource(); try validateEvidence()
        let path = Array(workspace.utf8)
        guard regionIndex == 1, request.frame.count == 107, path.count == 43,
              path.prefix(11).elementsEqual("checkpoint-".utf8),
              path.dropFirst(11).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...128 * 1024).contains(evidence.count) else { throw SNESCompatibilitySupportFrame.failure() }
        var frame = Data("HCRST31\0".utf8); frame.append(request.frame); frame.append(contentsOf: path)
        frame.append(originalPresent ? 1 : 2)
        let size = UInt32(evidence.count)
        for offset in 0..<4 { frame.append(UInt8(truncatingIfNeeded: size >> (offset * 8))) }
        frame.append(evidence)
        try appendRecoveryCurrent(current, to: &frame)
        for number in [observation.device, observation.inode] { for offset in 0..<8 { frame.append(UInt8(truncatingIfNeeded: number >> (offset * 8))) } }
        guard [1, 2].contains(intentKind) else { throw SNESCompatibilitySupportFrame.failure() }; frame.append(UInt8(intentKind))
        try validateEvidence(); try request.verifySource(); return frame
    }
    static func prepare(referenceDirectory: URL, currentDirectory: URL, backup: SNESLibraryBackup,
                        request: SNESCompatibilityLaunchRequest, observation: SNESRecoveryConsoleObservation,
                        workspace: String) throws -> Self {
        func failure() -> RecoveryProbeError { .refused("The clock recovery could not be verified. No console saves were changed.") }
        let entries = observation.pending.filter { $0.workspace == workspace }
        guard entries.count == 1, let entry = entries.first, entry.region == "battery.rtc", entry.workspacePresent else { throw failure() }
        let reference = try SNESCompatibilityRecoveryReference.openHistorical(directory: referenceDirectory, backup: backup, request: request)
        let retained = try SNESCompatibilityCurrentEvidence.open(directory: currentDirectory, referenceDirectory: referenceDirectory,
                                                                 backup: backup, request: request, observation: observation, region: .clock)
        let present: Bool, bytes: Data
        switch reference.evidence.clockOriginal {
        case .present(let original): present = true; bytes = original
        case .absent:
            guard case .present(let current) = retained.current else { throw failure() }
            present = false; bytes = current
        }
        guard (1...128 * 1024).contains(bytes.count) else { throw failure() }
        try reference.evidence.validate(request: request)
        return .init(workspace: workspace, regionIndex: 1, originalPresent: present, evidence: bytes, intentKind: entry.kind, current: retained.current, request: request,
                     referenceDirectory: referenceDirectory, currentDirectory: currentDirectory, backup: backup, observation: observation)
    }
}
