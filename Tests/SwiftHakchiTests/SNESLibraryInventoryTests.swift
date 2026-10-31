import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryInventoryTests {
    let hwid = String(repeating: "1", count: 32), context = String(repeating: "a", count: 64), catalog = String(repeating: "b", count: 64)
    func hex(_ value: String) -> String { Data(value.utf8).map { String(format: "%02x", $0) }.joined() }
    func frame(challenge: UUID, free: Int = 64000, menu: SNESLibraryMenu? = nil) throws -> Data {
        let empty = BackupManifest.digest(Data()), profile = Data("{}".utf8)
        var rows = ["SWIFTHAKCHI_SNES_LIBRARY_INVENTORY_V1 " + challenge.uuidString, "CONTEXT " + context, "HWID " + hwid,
            "CATALOG " + catalog, "SPACE 4096 76800 \(free)", "NAMESPACE \(menu == nil ? "absent absent" : "ready ready")"]
        if let menu {
            let wire = try SNESLibraryStartupScripts.manifest(for: menu), tree = BackupManifest.digest(wire)
            let selector = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(menu.id.uuidString)\n\(tree)\n".utf8)
            rows.append("SELECTOR library \(menu.id.uuidString) \(tree) \(BackupManifest.digest(selector))")
            rows.append("MENU library \(menu.id.uuidString) \(tree) \(wire.count) \(menu.manifest.count) \(BackupManifest.digest(menu.manifest))")
            for record in menu.objectRecords {
                rows.append("OBJECT \(record.name) \(record.byteCount) \(record.sha256)")
                rows.append("REF \(menu.id.uuidString) \(record.name)")
            }
            var files = Dictionary(uniqueKeysWithValues: menu.files.map { ("menus/\(menu.id.uuidString)/" + $0.key, $0.value) })
            for record in menu.objectRecords { files["objects/" + record.name] = menu.objects[record.name] }
            files["menus/\(menu.id.uuidString)/menu.manifest"] = wire
            files["descriptions/\(menu.id.uuidString).json"] = menu.manifest
            files["active-menu"] = selector
            for (index, path) in files.keys.sorted().enumerated() {
                let data = try #require(files[path])
                rows.append("FILE \(hex(path)) \(data.count) \(BackupManifest.digest(data)) 384 0 1 \(index+100) 0")
            }
        } else { rows.append("SELECTOR builtin - - \(empty)") }
        rows.append("DIR \(hex("clover")) 448")
        rows.append("FILE \(hex("clover/settings.json")) \(profile.count) \(BackupManifest.digest(profile)) 384 0 1 9999 0")
        rows.append("END")
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }
    func parse(_ raw: Data, challenge: UUID, expectedContext: String? = nil, now: Date = Date()) throws -> SNESLibraryInventory {
        try .init(raw: raw, challenge: challenge, contextSHA256: expectedContext ?? context, hwid: hwid, catalogSHA256: catalog, measuredAt: now)
    }
    @Test func realZeroSpaceIsDistinctFromMissingOrInvalidMeasurements() throws {
        let id = UUID(), result = try parse(frame(challenge: id, free: 0), challenge: id)
        #expect(result.capacity.freeBytes == 0 && result.capacity.blockSize == 4096)
        #expect(!result.capacity.namespaceReady)
        #expect(result.files.count == 1 && result.directories.count == 1)
        #expect(throws: (any Error).self) { try parse(Data(), challenge: id) }
    }
    @Test func currentBackupIdentityIgnoresFreeSpaceConnectionNonceAndUnusedObjects() throws {
        let first = UUID(), second = UUID(), now = Date()
        let a = try parse(frame(challenge: first), challenge: first, now: now)
        let b = try parse(frame(challenge: second, free: 62000), challenge: second, now: now.addingTimeInterval(100))
        #expect(a.snapshotSHA256 == b.snapshotSHA256)
        let otherContext = String(repeating: "c", count: 64)
        let changedContext = String(decoding: try frame(challenge: second), as: UTF8.self).replacingOccurrences(of: context, with: otherContext)
        #expect(try parse(Data(changedContext.utf8), challenge: second, expectedContext: otherContext).snapshotSHA256 == a.snapshotSHA256)
        let object = Data(repeating: 0, count: 256), hash = BackupManifest.digest(object)
        let unused = String(decoding: try frame(challenge: second), as: UTF8.self)
            .replacingOccurrences(of: "NAMESPACE absent absent", with: "NAMESPACE ready ready")
            .replacingOccurrences(of: "END\n", with: "OBJECT \(hash).sfrom 256 \(hash)\nEND\n")
        #expect(try parse(Data(unused.utf8), challenge: second).snapshotSHA256 == a.snapshotSHA256)
        let replacedFile = String(decoding: try frame(challenge: second), as: UTF8.self)
            .replacingOccurrences(of: " 1 9999 0\n", with: " 1 8888 10\n")
        let replacement = try parse(Data(replacedFile.utf8), challenge: second)
        #expect(replacement.snapshotSHA256 == a.snapshotSHA256 && replacement.stateSHA256 != a.stateSHA256)
        let changedSave = String(decoding: try frame(challenge: second), as: UTF8.self).replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(Data("[]".utf8)))
        #expect(try parse(Data(changedSave.utf8), challenge: second).snapshotSHA256 != a.snapshotSHA256)
    }
    @Test func libraryInventoryBindsBothMetadataFormatsAndReferencedObjects() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root), menu = try fixture.menu(review, originals)
        let id = UUID(), result = try parse(frame(challenge: id, menu: menu), challenge: id)
        #expect(result.capacity.objects.count == menu.objectRecords.count)
        #expect(result.capacity.namespaceReady && result.capacity.descriptionStoreReady)
        #expect(result.menus.count == 1 && result.menus[0].references.count == menu.objectRecords.count)
        #expect(result.files.contains { $0.path == "descriptions/\(menu.id.uuidString).json" })
        let original = String(decoding: try frame(challenge: id, menu: menu), as: UTF8.self)
        let object = try #require(menu.objectRecords.first)
        for changed in [original.replacingOccurrences(of: "NAMESPACE ready ready", with: "NAMESPACE ready absent"),
            original.replacingOccurrences(of: "REF \(menu.id.uuidString) \(object.name)\n", with: ""),
            original.replacingOccurrences(of: "END\n", with: "OBJECT \(object.name) \(object.byteCount) \(object.sha256)\nEND\n"),
            original.replacingOccurrences(of: "END\n", with: "FILE \(hex("menus/" + UUID().uuidString + "/menu.manifest")) 10 \(catalog) 384 0 1 8888 0\nEND\n")] {
            #expect(throws: (any Error).self) { try parse(Data(changed.utf8), challenge: id) }
        }
    }
    @Test func twoFileNamesCannotClaimTheSameSingleLinkFile() throws {
        let id = UUID(), hash = BackupManifest.digest(Data("{}".utf8))
        let raw = String(decoding: try frame(challenge: id), as: UTF8.self).replacingOccurrences(of: "END\n",
            with: "FILE \(hex("clover/other.json")) 2 \(hash) 384 0 1 9999 0\nEND\n")
        #expect(throws: (any Error).self) { try parse(Data(raw.utf8), challenge: id) }
    }
    @Test(arguments: ["nonce", "context", "hardware", "overflow", "block", "truncated", "extra", "duplicate", "parent", "nul", "encoded-slash", "special-mode"])
    func malformedFramesNeverBecomeCapacityOrBackupEvidence(_ fault: String) throws {
        let id = UUID(); var raw = String(decoding: try frame(challenge: id), as: UTF8.self)
        switch fault {
        case "nonce": raw = raw.replacingOccurrences(of: id.uuidString, with: UUID().uuidString)
        case "context": raw = raw.replacingOccurrences(of: context, with: String(repeating: "c", count: 64))
        case "hardware": raw = raw.replacingOccurrences(of: hwid, with: String(repeating: "2", count: 32))
        case "overflow": raw = raw.replacingOccurrences(of: "SPACE 4096 76800 64000", with: "SPACE 4096 9223372036854775807 64000")
        case "block": raw = raw.replacingOccurrences(of: "SPACE 4096", with: "SPACE 4097")
        case "truncated": raw.removeLast(4)
        case "extra": raw += "END\n"
        case "duplicate": raw = raw.replacingOccurrences(of: "END\n", with: "DIR \(hex("clover")) 448\nEND\n")
        case "parent": raw = raw.replacingOccurrences(of: hex("clover/settings.json"), with: hex("clover/../settings.json"))
        case "nul": raw = raw.replacingOccurrences(of: hex("clover/settings.json"), with: hex("clover/\u{0}settings.json"))
        case "encoded-slash": raw = raw.replacingOccurrences(of: hex("clover/settings.json"), with: hex("clover//settings.json"))
        default: raw = raw.replacingOccurrences(of: " 384 0 ", with: " 4480 0 ")
        }
        #expect(throws: (any Error).self) { try parse(Data(raw.utf8), challenge: id) }
    }
}
