import Foundation
import Darwin
import SwiftHakchiCore

/// A discovery hint, never proof that a connected console may be modified.
struct SNESLibraryInstallationReference: Codable, Hashable, Sendable {
    let hwid: String, operationID: UUID, reviewSHA256: String
    let catalog: URL, catalogSHA256: String
    func validate() throws {
        guard hwid.count == 32, SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }),
              SNESDataSnapshotChunk.isDigest(reviewSHA256), SNESDataSnapshotChunk.isDigest(catalogSHA256),
              catalog.isFileURL, catalog.path.hasPrefix("/"), catalog.path.utf8.count <= 4096, !catalog.path.contains("\0"),
              catalog == catalog.standardizedFileURL, catalog.lastPathComponent.hasPrefix("SNES-Original-Games-"),
              UUID(uuidString: String(catalog.lastPathComponent.dropFirst(20))) != nil else { throw SNESLibraryInstallation.failure() }
    }
}

enum SNESLibraryInstallationIndex {
    private struct Record: Codable {
        let version: Int, scope: String, reference: SNESLibraryInstallationReference
    }
    struct Loaded: Sendable {
        let reference: SNESLibraryInstallationReference, sha256: String
        private let seal: SNESFirmwareSourceSeal
        fileprivate init(reference: SNESLibraryInstallationReference, sha256: String, seal: SNESFirmwareSourceSeal) {
            self.reference = reference; self.sha256 = sha256; self.seal = seal
        }
        func validate() throws { try seal.validate() }
    }
    static func name(_ hwid: String) throws -> String {
        guard hwid.count == 32, SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }) else { throw SNESLibraryInstallation.failure() }
        return "SNES-" + BackupManifest.digest(Data(hwid.utf8)) + ".json"
    }
    static func load(hwid: String, root: URL) throws -> Loaded? {
        let directory = try RestoreDirectory(root), name = try name(hwid)
        var info = stat()
        if fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw SNESLibraryInstallation.failure() }; return nil
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_uid == geteuid() else { throw SNESLibraryInstallation.failure() }
        let path = directory.url.appendingPathComponent(name), seal = try SNESFirmwareSourceSeal.capture(directories: [], files: [path])
        let raw = try directory.read(name, maximum: 16384), record = try JSONDecoder().decode(Record.self, from: raw)
        guard record.version == 1, record.scope == "native-snes-installation-reference", record.reference.hwid == hwid,
              let actual = try JSONSerialization.jsonObject(with: raw) as? NSDictionary,
              let canonical = try JSONSerialization.jsonObject(with: encode(record)) as? [String: Any], actual.isEqual(to: canonical) else { throw SNESLibraryInstallation.failure() }
        try record.reference.validate(); try seal.validate(); try directory.check()
        return .init(reference: record.reference, sha256: BackupManifest.digest(raw), seal: seal)
    }
    static func save(_ reference: SNESLibraryInstallationReference, root: URL) throws -> URL {
        try reference.validate()
        let directory = try RestoreDirectory(root), leaf = try name(reference.hwid)
        let raw = try encode(Record(version: 1, scope: "native-snes-installation-reference", reference: reference))
        guard raw.count <= 16384 else { throw SNESLibraryInstallation.failure() }
        var prior = stat()
        if fstatat(directory.fd, leaf, &prior, AT_SYMLINK_NOFOLLOW) == 0 {
            _ = try load(hwid: reference.hwid, root: root)
        } else { guard errno == ENOENT else { throw SNESLibraryInstallation.failure() } }
        let temporary = ".snes-index-" + UUID().uuidString
        let fd = openat(directory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SNESLibraryInstallation.failure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlinkat(directory.fd, temporary, 0) }
        try handle.write(contentsOf: raw)
        guard fsync(fd) == 0 else { throw SNESLibraryInstallation.failure() }
        try directory.check()
        guard renameat(directory.fd, temporary, directory.fd, leaf) == 0, fsync(directory.fd) == 0 else { throw SNESLibraryInstallation.failure() }
        guard try load(hwid: reference.hwid, root: root)?.reference == reference else { throw SNESLibraryInstallation.failure() }
        return directory.url.appendingPathComponent(leaf)
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// Fully reconstructed owner evidence; no USB access or write permit is issued here.
struct SNESLibraryInstallation: Sendable {
    let accepted: SNESFirmwareAcceptedInstall, originals: SNESOriginalGamesPackage
    let expected: SNESStartupTrialExpectation, reference: SNESLibraryInstallationReference
    let catalogContentSHA256: String
    private let checked: SNESFirmwareGuard
    var supportsLibrarySync: Bool { accepted.material.trial.candidate.hasCorrectedLibrarySupport }
    var supportsNativeArtwork: Bool {accepted.material.trial.candidate.hasNativeArtworkSupport}
    static func failure() -> RecoveryProbeError {
        .refused("Reconnect the SNES and open console setup to check its saved recovery files.")
    }
    private init(accepted: SNESFirmwareAcceptedInstall, originals: SNESOriginalGamesPackage, expected: SNESStartupTrialExpectation,
                 reference: SNESLibraryInstallationReference, checked: SNESFirmwareGuard, catalogContentSHA256: String) {
        self.accepted = accepted; self.originals = originals; self.expected = expected; self.reference = reference; self.checked = checked
        self.catalogContentSHA256 = catalogContentSHA256
    }
    static func resolve(reference: SNESLibraryInstallationReference, journals: URL, recovery: RecoveryBootInputs) async throws -> Self {
        try reference.validate(); try Task.checkCancellation()
        let operation = journals.appendingPathComponent("SNESFirmware-" + reference.operationID.uuidString)
        // Reopening also refuses unresolved firmware work, including a recapture of the same hardware.
        let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: reference.reviewSHA256, recovery: recovery)
        let lineage: [SNESFirmwareAcceptedInstall]
        do { lineage = try await journal.acceptedLineage(); try await journal.close() }
        catch { try? await journal.close(); throw error }
        guard let accepted = lineage.first, accepted.material.id == reference.operationID,
              accepted.material.trial.candidate.material.binding.expectedHWID == reference.hwid else { throw failure() }
        let directory = try RestoreDirectory(reference.catalog), raw = try directory.read("manifest.json", maximum: 65536)
        guard BackupManifest.digest(raw) == reference.catalogSHA256,
              let manifest = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = manifest["operation"] as? String,
              let ancestor = lineage.first(where: { $0.material.id.uuidString == id }) else { throw failure() }
        let originals = try SNESOriginalGamesPackage.load(directory: directory.url, accepted: ancestor)
        guard originals.manifestSHA256 == reference.catalogSHA256,
              ancestor.material.trial.candidate.material.binding == accepted.material.trial.candidate.material.binding else { throw failure() }
        let checked = try SNESFirmwareGuard.prepare(accepted.material), expected = try SNESStartupTrialExpectation.checked(accepted.material.trial)
        let result = Self(accepted: accepted, originals: originals, expected: expected, reference: reference, checked: checked, catalogContentSHA256: try SNESLibraryCatalogIdentity.digest(originals.frame))
        try result.validate(); return result
    }
    func validate() throws {
        try Task.checkCancellation(); try accepted.history.validate(); try checked.require(accepted.material); try originals.revalidate()
    }
}

/// Fresh discovery response only. It chooses owner records; it grants no game access.
struct SNESLibraryIdentity: Sendable {
    let hwid: String
    init(_ raw: Data, challenge: UUID) throws {
        guard raw.count <= 1024, let text = String(data: raw, encoding: .ascii) else { throw SNESLibraryInstallation.failure() }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 8, lines[0] == "SWIFTHAKCHI_SNES_IDENTITY_V1", lines[1] == "CHALLENGE=" + challenge.uuidString,
              lines[2] == "BOARD=dp-shvc", lines[3] == "REGION=USA", lines[4] == "KERNEL=3.4.113",
              lines[5].hasPrefix("HWID="), lines[6] == "END", lines[7].isEmpty else { throw SNESLibraryInstallation.failure() }
        let chip = String(lines[5].dropFirst(5))
        guard chip.count == 32, SNESRuntimeBinding.hex(chip), chip.contains(where: { $0 != "0" }) else { throw SNESLibraryInstallation.failure() }
        hwid = chip
    }
}

struct SNESLibraryFirmwareReference: Sendable {
    let id: UUID, reviewSHA256: String, hwid: String, parentID: UUID?
    let candidate: URL, imageSHA256: String, isCurrentCandidate: Bool
}

extension SNESLibraryInstallationIndex {
    /// Migration/discovery only. The selected reference is fully reopened before it is cached or used.
    static func discover(hwid: String, deviceVersion: UInt16, journals: URL, backups: [URL]) throws -> SNESLibraryInstallationReference? {
        _ = try name(hwid)
        guard (UInt16(0x6a04)...UInt16(0x6a0b)).contains(deviceVersion), backups.count <= 16 else { throw SNESLibraryInstallation.failure() }
        let records = try SNESFirmwareJournal.acceptedReferences(root: journals, hwid: hwid)
        var matching: [SNESLibraryFirmwareReference] = []
        for record in records where record.isCurrentCandidate {
            let directory = try RestoreDirectory(record.candidate), raw = try directory.read("manifest.json", maximum: 65536)
            guard let m = try JSONSerialization.jsonObject(with: raw) as? [String: Any], m["imageSHA256"] as? String == record.imageSHA256 else { throw SNESLibraryInstallation.failure() }
            let version = m["schemaVersion"] as? Int
            if let version,(3...10).contains(version),deviceVersion==UInt16(version)+0x6a01 {matching.append(record)}
        }
        guard matching.count <= 1 else { throw SNESLibraryInstallation.failure() }
        guard let current = matching.first else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var ancestor: SNESLibraryFirmwareReference? = current, seen = Set<UUID>()
        while let value = ancestor {
            guard seen.count < 8, seen.insert(value.id).inserted else { throw SNESLibraryInstallation.failure() }
            for root in backups {
                let directory = try RestoreDirectory(root)
                let names = try directory.names().filter { $0.hasPrefix("SNES-Original-Games-") }
                guard names.count <= 64 else { throw SNESLibraryInstallation.failure() }
                for name in names {
                    let catalog = try RestoreDirectory(directory.url.appendingPathComponent(name)), raw = try catalog.read("manifest.json", maximum: 65536)
                    guard let m = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let binding = m["binding"] as? [String: Any] else { throw SNESLibraryInstallation.failure() }
                    guard m["operation"] as? String == value.id.uuidString, m["reviewSHA256"] as? String == value.reviewSHA256,
                          binding["expectedHWID"] as? String == hwid, m["imageSHA256"] as? String == value.imageSHA256 else { continue }
                    let reference = SNESLibraryInstallationReference(hwid: hwid, operationID: current.id, reviewSHA256: current.reviewSHA256,
                        catalog: catalog.url, catalogSHA256: BackupManifest.digest(raw))
                    try reference.validate(); return reference
                }
            }
            if let id = value.parentID {
                guard let parent = byID[id] else { throw SNESLibraryInstallation.failure() }; ancestor = parent
            } else { ancestor = nil }
        }
        return nil
    }
}

/// A source-checked, challenge-checked attachment. Transactions still require their own permits.
struct SNESLibraryContext: Sendable {
    let installation: SNESLibraryInstallation, attachment: RecoveryProbeUSBDevice, sessionID: UUID, sha256: String
    private let index: SNESLibraryInstallationIndex.Loaded
    var supportsLibrarySync: Bool { installation.supportsLibrarySync }
    var supportsNativeArtwork: Bool {installation.supportsNativeArtwork}
    var supportsLibraryRecovery: Bool { installation.accepted.material.trial.candidate.hasLibrarySupport }
    private struct Record: Encodable {
        let version: Int, session: UUID, attachment: RecoveryProbeUSBDevice
        let operation: UUID, reviewSHA256: String, catalogSHA256: String, indexSHA256: String, reportsSHA256: [String]
    }
    private init(installation: SNESLibraryInstallation, index: SNESLibraryInstallationIndex.Loaded, attachment: RecoveryProbeUSBDevice,
                 sessionID: UUID, sha256: String) {
        self.installation = installation; self.index = index; self.attachment = attachment; self.sessionID = sessionID; self.sha256 = sha256
    }
    static func verify(installation: SNESLibraryInstallation, index: SNESLibraryInstallationIndex.Loaded,
                       attachment: RecoveryProbeUSBDevice, sessionID: UUID, challenges: [UUID], reports: [Data]) throws -> Self {
        try installation.validate(); try index.validate()
        _ = try SNESStartupTrialUSBPolicy.nativeIdentity(attachment)
        guard ConsoleAttachmentPolicy.kind(of: attachment) == .nativeSNES, attachment.deviceVersion == installation.expected.deviceVersion,
              index.reference == installation.reference, challenges.count == 2, Set(challenges).count == 2, reports.count == 2 else { throw SNESLibraryInstallation.failure() }
        let first = try SNESStartupTrialReport(reports[0], expected: installation.expected, challenge: challenges[0])
        let last = try SNESStartupTrialReport(reports[1], expected: installation.expected, challenge: challenges[1])
        guard first.mcpPID == last.mcpPID, first.daemonPID == last.daemonPID else { throw SNESLibraryInstallation.failure() }
        let record = Record(version: 1, session: sessionID, attachment: attachment, operation: installation.accepted.material.id,
            reviewSHA256: installation.accepted.reviewSHA256, catalogSHA256: installation.originals.manifestSHA256,
            indexSHA256: index.sha256, reportsSHA256: reports.map(BackupManifest.digest))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = Self(installation: installation, index: index, attachment: attachment, sessionID: sessionID,
            sha256: BackupManifest.digest(try encoder.encode(record)))
        try value.requireCurrent(attachment: attachment, sessionID: sessionID); return value
    }
    /// Inert checked source records for a new exclusive session, which must get its own fresh device reports.
    func ownerRecords() throws -> SNESLibraryOwnerRecords {
        try requireCurrent(attachment: attachment, sessionID: sessionID)
        return .init(installation: installation, index: index)
    }
    func requireCurrent(attachment: RecoveryProbeUSBDevice, sessionID: UUID) throws {
        guard attachment == self.attachment, sessionID == self.sessionID else { throw SNESLibraryInstallation.failure() }
        try installation.validate(); try index.validate()
    }
}

extension SNESLibraryIdentity {
    static func command(challenge: UUID) -> String {
        #"""
        set -eu
        B=/mnt/swifthakchi/busybox
        test -f "$B" && test ! -L "$B"
        test "$("$B" stat -c '%h:%u' "$B")" = 1:0
        pin=$("$B" sha256sum "$B")
        test "${pin%% *}" = 440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6
        test "$("$B" uname -r)" = 3.4.113
        test "$("$B" cat /etc/clover/boardtype)" = dp-shvc
        test "$("$B" cat /etc/clover/REGION)" = USA
        chip=''
        for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
          word=$("$B" devmem "$address" 32); chip="$chip$(printf '%08x' "$word")"
        done
        case "$chip" in ''|*[!0-9a-f]*) exit 1;; esac
        test "${#chip}" = 32 && test "$chip" != 00000000000000000000000000000000
        printf 'SWIFTHAKCHI_SNES_IDENTITY_V1\nCHALLENGE=__NONCE__\nBOARD=dp-shvc\nREGION=USA\nKERNEL=3.4.113\nHWID=%s\nEND\n' "$chip"
        """#.replacingOccurrences(of: "__NONCE__", with: challenge.uuidString) + "\n"
    }
}
extension SNESLibraryInstallationIndex {
    static func defaultRoot() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw SNESLibraryInstallation.failure() }
        return support.appendingPathComponent("SwiftHakchi/ConsoleRecords/SNES", isDirectory: true).standardizedFileURL
    }
    static func ensureRoot() throws -> URL {
        let path = try defaultRoot()
        guard path == path.resolvingSymlinksInPath() else { throw SNESLibraryInstallation.failure() }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = try RestoreDirectory(path)
        guard fchmod(directory.fd, 0o700) == 0 else { throw SNESLibraryInstallation.failure() }
        try directory.check(); return directory.url
    }
}

extension SNESLibraryInstallationIndex {
    static func existingPrivateRoot(_ path:URL)throws->URL {
        let directory=try RestoreDirectory(path);var info=stat()
        guard fstat(directory.fd,&info)==0,info.st_uid==geteuid(),info.st_mode & 0o777 == 0o700 else {throw SNESLibraryInstallation.failure()}
        try directory.check();return directory.url
    }
}
