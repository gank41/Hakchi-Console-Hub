import Foundation
import SwiftHakchiCore

/// Inert bounded console data. Only a checked native session can attest it for a transaction.
struct SNESLibraryInventory: Sendable {
    static let maximumFrameBytes = 16 * 1024 * 1024
    enum MenuKind: String, Codable, Sendable { case builtin, legacy, library }
    struct Selection: Codable, Equatable, Sendable {
        let kind: MenuKind, id: UUID?, treeSHA256: String?, selectorSHA256: String
        func bytes() throws -> Data {
            switch kind {
            case .builtin:
                guard id == nil, treeSHA256 == nil else { throw SNESLibraryInventory.failure() }
                return selectorSHA256 == BackupManifest.digest(Data()) ? Data() : Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nBUILTIN\n".utf8)
            case .legacy, .library:
                guard let id, let treeSHA256, SNESDataSnapshotChunk.isDigest(treeSHA256) else { throw SNESLibraryInventory.failure() }
                let header = kind == .legacy ? "SWIFTHAKCHI_SNES_MENU_SELECTOR_V1\n" : "SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n"
                return Data((header + id.uuidString + "\n" + treeSHA256 + "\n").utf8)
            }
        }
    }
    struct FileIdentity: Codable, Equatable, Sendable { let device: UInt64, inode: UInt64, changed: Int64 }
    struct File: Codable, Equatable, Sendable {
        let path: String, byteCount: Int, sha256: String, mode: Int, modified: Int64, identity: FileIdentity
    }
    private struct ContentFile: Encodable {
        let path: String, byteCount: Int, sha256: String, mode: Int, modified: Int64
        init(_ file: File) { path = file.path; byteCount = file.byteCount; sha256 = file.sha256; mode = file.mode; modified = file.modified }
    }
    struct Directory: Codable, Equatable, Sendable { let path: String, mode: Int }
    struct Menu: Codable, Equatable, Sendable {
        let kind: MenuKind, id: UUID, treeSHA256: String, manifestBytes: Int, descriptionBytes: Int, descriptionSHA256: String?
        let references: [String]
    }
    let contextSHA256: String, hwid: String, catalogSHA256: String, selection: Selection
    let files: [File], directories: [Directory], menus: [Menu], capacity: SNESLibraryCapacity.Inventory
    let snapshotSHA256: String, stateSHA256: String, totalBytes: Int64
    let rawFrame: Data, challenge: UUID
    let excludedMenuID: UUID?
    let incompleteNamespace: Bool
    private struct Snapshot: Encodable {
        let version = 1
        let hwid: String, catalogSHA256: String, selection: Selection, files: [ContentFile], directories: [Directory]
    }
    private struct State: Encodable {
        let snapshotSHA256: String, objects: [SNESLibraryObjects.Record], menus: [Menu], namespaceReady: Bool, descriptionStoreReady: Bool
        let fileIdentities: [String: FileIdentity]
        let excludedMenuID: UUID?
        let incompleteNamespace: Bool?
    }
    static func failure() -> RecoveryProbeError {
        .refused("The SNES game list or available space could not be checked. Return to the game menu and refresh the console review.")
    }
    static func safePath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && value.utf8.count <= 512 && !value.contains("\\")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && parts.count <= 12 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }
    private static func uuid(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value), id.uuidString == value else { throw failure() }; return id
    }
    private static func decodedPath(_ text: String) throws -> String {
        guard !text.isEmpty, text.utf8.count <= 1024, text.utf8.count % 2 == 0,
              text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw failure() }
        let chars = Array(text.utf8); var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        func digit(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
        for i in stride(from: 0, to: chars.count, by: 2) { bytes.append(digit(chars[i]) * 16 + digit(chars[i+1])) }
        guard let value = String(bytes: bytes, encoding: .utf8), safePath(value) else { throw failure() }; return value
    }
    static func limit(for path: String) throws -> Int {
        if path.hasPrefix("clover/") { return 16 * 1024 * 1024 }
        if path == "active-menu" || path == "legacy/active-menu" { return 256 }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "objects" { return 4 * 1024 * 1024 + 96 }
        if parts.count == 2, parts[0] == "descriptions", parts[1].hasSuffix(".json") {
            _ = try uuid(String(parts[1].dropLast(5))); return 1024 * 1024
        }
        if parts.count == 3, parts[0] == "menus", parts[2] == "menu.manifest" { _ = try uuid(parts[1]); return 1024 * 1024 }
        if parts.count == 6, parts[0] == "menus", parts[2] == "pages" {
            _=try uuid(parts[1])
            return try SNESLibraryMenu.fileLimit(parts[2...5].joined(separator:"/"),version:2)
        }
        if parts.count == 4, parts[0] == "legacy", parts[1] == "menus", parts[3] == "menu.manifest" { _ = try uuid(parts[2]); return 32768 }
        if parts.count == 6, parts[0] == "legacy", parts[1] == "menus", parts[3] == "games",
           parts[4].range(of: #"^CLV-[PU]-[A-Z0-9]{5}$"#, options: .regularExpression) != nil {
            _ = try uuid(parts[2]); let name = parts[5], code = parts[4]
            if name == code + ".desktop" { return 16384 }
            if code.hasPrefix("CLV-U-") {
                if name == code + ".sfrom" { return 4 * 1024 * 1024 + 96 }
                if name == code + ".png" || name == code + "_small.png" { return 262144 }
            }
        }
        throw failure()
    }
    init(raw: Data, challenge: UUID, contextSHA256: String, hwid: String, catalogSHA256: String, measuredAt: Date = Date(), excludingIncompleteMenu: UUID? = nil) throws {
        guard raw.count <= Self.maximumFrameBytes, let text = String(data: raw, encoding: .ascii), text.hasSuffix("\n"),
              text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) }),
              SNESDataSnapshotChunk.isDigest(contextSHA256), SNESDataSnapshotChunk.isDigest(catalogSHA256),
              hwid.count == 32, SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }) else { throw Self.failure() }
        let lines = text.components(separatedBy: "\n").dropLast()
        guard (9...50000).contains(lines.count), lines.first == (excludingIncompleteMenu == nil ? "SWIFTHAKCHI_SNES_LIBRARY_INVENTORY_V1 " : "SWIFTHAKCHI_SNES_LIBRARY_RECOVERY_INVENTORY_V1 ") + challenge.uuidString,
              lines[1] == "CONTEXT " + contextSHA256, lines[2] == "HWID " + hwid, lines[3] == "CATALOG " + catalogSHA256,
              lines.last == "END", lines.allSatisfy({ $0.utf8.count <= 2048 }) else { throw Self.failure() }
        func fields(_ row: String, _ count: Int) throws -> [String] {
            let parts = row.components(separatedBy: " ")
            guard parts.count == count, parts.allSatisfy({ !$0.isEmpty }) else { throw Self.failure() }; return parts
        }
        func number(_ value: String, _ range: ClosedRange<Int64>) throws -> Int64 {
            guard let n = Int64(value), String(n) == value, range.contains(n) else { throw Self.failure() }; return n
        }
        let space = try fields(lines[4], 4)
        guard space[0] == "SPACE" else { throw Self.failure() }
        let block = try number(space[1], 512...65536), total = try number(space[2], 1...1048576), available = try number(space[3], 0...total)
        let (totalBytes, overflow) = block.multipliedReportingOverflow(by: total)
        guard !overflow, block.nonzeroBitCount == 1, totalBytes <= 512 * 1024 * 1024 else { throw Self.failure() }
        let namespace = try fields(lines[5], 3)
        let partial = namespace[1] == "partial"
        guard namespace[0] == "NAMESPACE", ["ready", "absent", "partial"].contains(namespace[1]), ["ready", "absent"].contains(namespace[2]),
              !partial || excludingIncompleteMenu != nil,
              namespace[1] == "ready" || partial || namespace[2] == "absent" else { throw Self.failure() }
        let ready = namespace[1] == "ready", descriptions = namespace[2] == "ready", selector = try fields(lines[6], 5)
        guard selector[0] == "SELECTOR", let kind = MenuKind(rawValue: selector[1]), SNESDataSnapshotChunk.isDigest(selector[4]) else { throw Self.failure() }
        let selected: Selection
        if kind == .builtin {
            guard selector[2] == "-", selector[3] == "-" else { throw Self.failure() }
            selected = .init(kind: kind, id: nil, treeSHA256: nil, selectorSHA256: selector[4])
        } else {
            guard SNESDataSnapshotChunk.isDigest(selector[3]), kind != .library || ready else { throw Self.failure() }
            selected = .init(kind: kind, id: try Self.uuid(selector[2]), treeSHA256: selector[3], selectorSHA256: selector[4])
        }
        guard excludingIncompleteMenu == nil || selected.id != excludingIncompleteMenu else { throw Self.failure() }
        let selectionBytes = try selected.bytes()
        guard BackupManifest.digest(selectionBytes) == selected.selectorSHA256 else { throw Self.failure() }
        var objects: [String: SNESLibraryObjects.Record] = [:], files: [String: File] = [:], directories: [String: Directory] = [:]
        var menuRows: [String: Menu] = [:], references: [UUID: Set<String>] = [:]
        var fileBytes: Int64 = 0, objectBytes: Int64 = 0
        var fileIdentities = Set<String>(), exclusionSeen = false
        for row in lines.dropFirst(7).dropLast() {
            try Task.checkCancellation()
            switch row.components(separatedBy: " ").first {
            case "EXCLUDED":
                let p = try fields(row, 2)
                guard !exclusionSeen, let excludingIncompleteMenu, p[1] == excludingIncompleteMenu.uuidString else { throw Self.failure() }
                exclusionSeen = true
            case "OBJECT":
                let p = try fields(row, 4), n = try number(p[2], 1...Int64(4 * 1024 * 1024 + 96))
                let record = SNESLibraryObjects.Record(name: p[1], byteCount: Int(n), sha256: p[3]); try record.validate()
                guard ready || partial, objects.updateValue(record, forKey: p[1]) == nil, objects.count <= 2048 else { throw Self.failure() }
                objectBytes += n; guard objectBytes <= 256 * 1024 * 1024 else { throw Self.failure() }
            case "MENU":
                let p = try fields(row, 7)
                guard let k = MenuKind(rawValue: p[1]), k != .builtin, k != .library || (ready && descriptions), SNESDataSnapshotChunk.isDigest(p[3]) else { throw Self.failure() }
                let id = try Self.uuid(p[2]), n = try number(p[4], 1...1048576), descriptionBytes = try number(p[5], 0...1048576)
                guard k == .library ? (descriptionBytes > 0 && SNESDataSnapshotChunk.isDigest(p[6])) : (descriptionBytes == 0 && p[6] == "-" && n <= 32768) else { throw Self.failure() }
                guard id != excludingIncompleteMenu else { throw Self.failure() }
                let record = Menu(kind: k, id: id, treeSHA256: p[3], manifestBytes: Int(n), descriptionBytes: Int(descriptionBytes), descriptionSHA256: k == .library ? p[6] : nil, references: [])
                guard menuRows.updateValue(record, forKey: k.rawValue + ":" + id.uuidString) == nil, menuRows.count <= 32 else { throw Self.failure() }
            case "REF":
                let p = try fields(row, 3), id = try Self.uuid(p[1])
                guard references[id, default: []].insert(p[2]).inserted, references[id]!.count <= 1024 else { throw Self.failure() }
            case "FILE":
                let p = try fields(row, 9), path = try Self.decodedPath(p[1]), limit = try Self.limit(for: path)
                let n = try number(p[2], 0...Int64(limit)), mode = try number(p[4], 0...511), modified = try number(p[5], 0...4102444800)
                guard SNESDataSnapshotChunk.isDigest(p[3]), n > 0 || path.hasPrefix("clover/") else { throw Self.failure() }
                let device = try number(p[6], 0...4294967295), inode = try number(p[7], 1...Int64.max), changed = try number(p[8], 0...4102444800)
                guard fileIdentities.insert("\(device):\(inode)").inserted else { throw Self.failure() }
                let value = File(path: path, byteCount: Int(n), sha256: p[3], mode: Int(mode), modified: modified,
                    identity: .init(device: UInt64(device), inode: UInt64(inode), changed: changed))
                guard files.updateValue(value, forKey: path) == nil, files.count <= 8192 else { throw Self.failure() }
                fileBytes += n; guard fileBytes <= totalBytes else { throw Self.failure() }
            case "DIR":
                let p = try fields(row, 3), path = try Self.decodedPath(p[1]), mode = try number(p[2], 0...511)
                guard path == "clover" || path.hasPrefix("clover/"), directories.updateValue(.init(path: path, mode: Int(mode)), forKey: path) == nil,
                      directories.count <= 2048 else { throw Self.failure() }
            default: throw Self.failure()
            }
        }
        guard exclusionSeen == (excludingIncompleteMenu != nil), directories["clover"] != nil, Set(files.keys).isDisjoint(with: directories.keys) else { throw Self.failure() }
        for path in (Array(directories.keys) + files.keys.filter { $0.hasPrefix("clover/") }) where path != "clover" {
            let parent = String(path[..<path.lastIndex(of: "/")!]); guard directories[parent] != nil else { throw Self.failure() }
        }
        for (id, names) in references {
            let key = "library:" + id.uuidString
            guard let m = menuRows[key], names.isSubset(of: Set(objects.keys)) else { throw Self.failure() }
            menuRows[key] = .init(kind: m.kind, id: m.id, treeSHA256: m.treeSHA256, manifestBytes: m.manifestBytes,
                descriptionBytes: m.descriptionBytes, descriptionSHA256: m.descriptionSHA256, references: names.sorted())
        }
        let active: Menu?
        if let id = selected.id {
            guard let found = menuRows[kind.rawValue + ":" + id.uuidString], found.treeSHA256 == selected.treeSHA256 else { throw Self.failure() }; active = found
        } else { active = nil }
        var observedObjects = Set<String>()
        let selectorPath = kind == .legacy ? "legacy/active-menu" : "active-menu"
        if !selectionBytes.isEmpty {
            guard files[selectorPath]?.sha256 == selected.selectorSHA256, files[selectorPath]?.byteCount == selectionBytes.count else { throw Self.failure() }
        }
        for file in files.values where !file.path.hasPrefix("clover/") {
            if file.path == selectorPath, !selectionBytes.isEmpty { continue }
            if file.path.hasPrefix("objects/") {
                let name = String(file.path.dropFirst(8))
                guard kind == .library, let object = objects[name], active?.references.contains(name) == true,
                      object.byteCount == file.byteCount, object.sha256 == file.sha256 else { throw Self.failure() }
                observedObjects.insert(name); continue
            }
            guard let active else { throw Self.failure() }
            let prefix = kind == .library ? "menus/\(active.id.uuidString)/" : "legacy/menus/\(active.id.uuidString)/"
            if file.path == "descriptions/\(active.id.uuidString).json", kind == .library {
                guard file.byteCount == active.descriptionBytes, file.sha256 == active.descriptionSHA256 else { throw Self.failure() }; continue
            }
            guard file.path.hasPrefix(prefix) else { throw Self.failure() }
        }
        if let active {
            let prefix = kind == .library ? "menus/\(active.id.uuidString)/" : "legacy/menus/\(active.id.uuidString)/"
            guard files[prefix + "menu.manifest"]?.sha256 == active.treeSHA256, files[prefix + "menu.manifest"]?.byteCount == active.manifestBytes else { throw Self.failure() }
            if kind == .library {
                guard observedObjects == Set(active.references), files["descriptions/\(active.id.uuidString).json"]?.sha256 == active.descriptionSHA256 else { throw Self.failure() }
            }
        }
        let sortedFiles = files.values.sorted { $0.path < $1.path }, sortedDirectories = directories.values.sorted { $0.path < $1.path }
        let sortedMenus = menuRows.values.sorted { ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let snapshot = Snapshot(hwid: hwid, catalogSHA256: catalogSHA256, selection: selected, files: sortedFiles.map(ContentFile.init), directories: sortedDirectories)
        let snapshotSHA = BackupManifest.digest(try encoder.encode(snapshot))
        self.rawFrame = raw; self.challenge = challenge; excludedMenuID = excludingIncompleteMenu; incompleteNamespace = partial
        self.contextSHA256 = contextSHA256; self.hwid = hwid; self.catalogSHA256 = catalogSHA256; selection = selected; self.totalBytes = totalBytes
        self.files = sortedFiles; self.directories = sortedDirectories; menus = sortedMenus; snapshotSHA256 = snapshotSHA
        stateSHA256 = BackupManifest.digest(try encoder.encode(State(snapshotSHA256: snapshotSHA, objects: objects.values.sorted { $0.name < $1.name },
            menus: sortedMenus, namespaceReady: ready, descriptionStoreReady: descriptions,
            fileIdentities: Dictionary(uniqueKeysWithValues: sortedFiles.map { ($0.path, $0.identity) }), excludedMenuID: excludingIncompleteMenu, incompleteNamespace: partial ? true : nil)))
        capacity = .init(measuredAt: measuredAt, contextSHA256: contextSHA256, freeBytes: available * block, blockSize: block,
            objects: objects, namespaceReady: ready, descriptionStoreReady: descriptions)
    }
}
