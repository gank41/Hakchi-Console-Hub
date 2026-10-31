import Foundation
import SwiftHakchiCore

/// Reconstructs inert Mac material from a verified snapshot. No console access or writes.
struct SNESLibraryRestore: Sendable {
    let backup: SNESLibraryBackup, menu: SNESLibraryMenu?
    static func prepare(backup: SNESLibraryBackup, originals: SNESOriginalGamesFrame, expectedHWID: String, id: UUID = UUID()) throws -> Self {
        let saved = try SNESLibraryBackup.open(directory: backup.directory), inventory = saved.inventory
        guard saved.manifestSHA256 == backup.manifestSHA256, inventory.hwid == expectedHWID,
              inventory.catalogSHA256 == (try SNESLibraryCatalogIdentity.digest(originals)) else { throw SNESLibraryInventory.failure() }
        switch inventory.selection.kind {
        case .builtin: return .init(backup: saved, menu: nil)
        case .legacy: return .init(backup: saved, menu: try migrateLegacy(saved, originals: originals, id: id))
        case .library:
            guard let oldID = inventory.selection.id else { throw SNESLibraryMenu.failure() }
            let raw = try saved.read(path: "descriptions/\(oldID.uuidString).json")
            let description = try JSONDecoder().decode(SNESLibraryMenu.Manifest.self, from: raw)
            guard raw == (try SNESLibraryMenu.encode(description)), description.id == oldID else { throw SNESLibraryMenu.failure() }
            var files: [String: Data] = [:], objects: [String: Data] = [:]
            for record in description.files { files[record.path] = try saved.read(path: "menus/\(oldID.uuidString)/" + record.path) }
            for record in description.objects {
                let bytes = try saved.read(path: "objects/" + record.name)
                if record.name.hasSuffix(".sfrom") {
                    guard bytes.count >= 96, try SNESCanoeImage.prepare(rom: Data(bytes[48..<(bytes.count-48)])).data == bytes else { throw SNESLibraryMenu.failure() }
                }
                objects[record.name] = bytes
            }
            let old = try make(description, files: files, objects: objects)
            try old.validate()
            guard try saved.read(path: "menus/\(oldID.uuidString)/menu.manifest") == SNESLibraryStartupScripts.manifest(for: old) else { throw SNESLibraryMenu.failure() }
            try validateStock(old, originals: originals)
            if description.version==2 {
                let oldPrefix="Icon="+old.consoleRoot+"/",newPrefix="Icon="+SNESLibraryMenu.namespace+"/menus/"+id.uuidString+"/"
                for path in files.keys where path.hasSuffix(".desktop") {
                    guard let raw=files[path],let text=String(data:raw,encoding:.utf8) else {throw SNESLibraryMenu.failure()}
                    files[path]=Data(text.components(separatedBy:"\n").map {$0.hasPrefix(oldPrefix) ? newPrefix+String($0.dropFirst(oldPrefix.count)):$0}.joined(separator:"\n").utf8)
                }
            }
            for placement in description.placements where placement.kind == "import" {
                let path = String(format: "pages/%03d/%@/%@.desktop", placement.page, placement.code, placement.code)
                guard let raw = files[path] else { throw SNESLibraryMenu.failure() }
                files[path] = try SNESLibraryMenu.cloverDesktop(raw)
            }
            let fileRecords=description.files.map {record in
                SNESLibraryMenu.FileRecord(path:record.path,byteCount:files[record.path]!.count,sha256:BackupManifest.digest(files[record.path]!))
            }
            let next = SNESLibraryMenu.Manifest(version: description.version, id: id, catalogSHA256: BackupManifest.digest(originals.raw), graph: description.graph,
                structure: description.structure, order: description.order, objects: description.objects, files: fileRecords,
                stock: description.stock, placements: description.placements)
            let menu = try make(next, files: files, objects: objects); try menu.validate()
            return .init(backup: saved, menu: menu)
        }
    }
    private static func make(_ description: SNESLibraryMenu.Manifest, files: [String: Data], objects: [String: Data]) throws -> SNESLibraryMenu {
        let sources: [SNESLibrarySourceFile] = []
        return .init(description: description, files: files, objects: objects, sources: sources,
            manifest: try SNESLibraryMenu.encode(description), sourceSHA256: BackupManifest.digest(try SNESLibraryMenu.encode(sources)))
    }
    static func validateStock(_ menu: SNESLibraryMenu, originals: SNESOriginalGamesFrame) throws {
        let entries = Dictionary(uniqueKeysWithValues: originals.entries.map { ($0.code, $0) })
        for reference in menu.description.stock {
            guard let entry = entries[reference.code], let desktop = entry.files.first(where: { $0.name == entry.code + ".desktop" }),
                  reference.desktopSHA256 == BackupManifest.digest(desktop.data), reference.romSHA256 == entry.romSHA256,
                  reference.romBytes == entry.romBytes else { throw SNESLibraryMenu.failure() }
            var expected = try SNESOneGameMenu.fields(desktop.data); expected.removeValue(forKey: "sortrawtitle")
            for placement in menu.description.placements where placement.code == entry.code {
                let path = String(format: "pages/%03d/%@/%@.desktop", placement.page, entry.code, entry.code)
                guard let bytes = menu.files[path] else { throw SNESLibraryMenu.failure() }
                var actual = try SNESOneGameMenu.fields(bytes); actual.removeValue(forKey: "sortrawtitle")
                guard actual == expected else { throw SNESLibraryMenu.failure() }
            }
        }
    }
    private static func replace(_ raw: Data, fields: [String: String]) throws -> Data {
        _ = try SNESOneGameMenu.fields(raw)
        guard let text = String(data: raw, encoding: .utf8) else { throw SNESLibraryMenu.failure() }
        var remaining = fields, lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line == "[Description]" { break }
            if let equal = line.firstIndex(of: "="), let value = remaining.removeValue(forKey: String(line[..<equal]).lowercased()) {
                lines.append(String(line[..<equal]) + "=" + value)
            } else { lines.append(line) }
        }
        while lines.last == "" { lines.removeLast() }
        if !remaining.isEmpty {
            let names = ["sortrawtitle": "SortRawTitle", "code": "Code", "exec": "Exec", "path": "Path", "icon": "Icon"]
            lines.append("[X-CLOVER Game]")
            for key in remaining.keys.sorted() {
                guard let name = names[key], let value = remaining[key] else { throw SNESLibraryMenu.failure() }
                lines.append(name + "=" + value)
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    private static func migrateLegacy(_ saved: SNESLibraryBackup, originals: SNESOriginalGamesFrame, id: UUID) throws -> SNESLibraryMenu {
        guard let oldID = saved.inventory.selection.id else { throw SNESLibraryMenu.failure() }
        let prefix = "legacy/menus/\(oldID.uuidString)/"
        var legacy: [String: Data] = [:]
        for file in saved.inventory.files where file.path.hasPrefix(prefix) && file.path != prefix + "menu.manifest" {
            legacy[String(file.path.dropFirst(prefix.count))] = try saved.read(path: file.path)
        }
        let wire = Data(("SWIFTHAKCHI_SNES_MENU_V1\n" + legacy.keys.sorted().map { BackupManifest.digest(legacy[$0]!) + " " + String(legacy[$0]!.count) + " " + $0 + "\n" }.joined()).utf8)
        guard try saved.read(path: prefix + "menu.manifest") == wire else { throw SNESLibraryMenu.failure() }
        var desktops: [String: Data] = [:], objects: [String: Data] = [:], custom: [String: (String, String, String)] = [:]
        let stock = Dictionary(uniqueKeysWithValues: originals.entries.map { ($0.code, $0) })
        for (path, raw) in legacy where path.hasSuffix(".desktop") {
            let bits = path.components(separatedBy: "/")
            guard bits.count == 3, bits[0] == "games", bits[2] == bits[1] + ".desktop" else { throw SNESLibraryMenu.failure() }
            let code = bits[1]; desktops[code] = raw
            if let original = stock[code] {
                guard original.files.first(where: { $0.name == code + ".desktop" })?.data == raw else { throw SNESLibraryMenu.failure() }
            } else {
                guard code.range(of: #"^CLV-U-[A-Z0-9]{5}$"#, options: .regularExpression) != nil,
                      let sfrom = legacy["games/\(code)/\(code).sfrom"], sfrom.count >= 96,
                      try SNESCanoeTrialImage(rom: Data(sfrom[48..<(sfrom.count-48)])).data == sfrom,
                      let large = legacy["games/\(code)/\(code).png"], let small = legacy["games/\(code)/\(code)_small.png"] else { throw SNESLibraryMenu.failure() }
                let rom = BackupManifest.digest(sfrom) + ".sfrom"; objects[rom] = sfrom
                let pair = SNESLibraryObjects.storeImages((large, small), in: &objects)
                custom[code] = (rom, pair.large, pair.small)
            }
        }
        guard custom.count == 1, Set(desktops.keys) == Set(stock.keys).union(custom.keys), legacy.count == stock.count + 4 else { throw SNESLibraryMenu.failure() }
        let games = desktops.map { Game(code: $0.key, desktopContent: String(decoding: $0.value, as: UTF8.self), consoleType: .snesUsa, source: stock[$0.key] == nil ? .local : .stock) }
        let structure = ConsoleStructure(mode: .flat, maximumGamesPerPage: .thirtyFive)
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: Set(stock.keys), order: .title, structure: structure)
        var files: [String: Data] = [:], placements: [SNESLibraryMenu.Placement] = []
        for page in graph.screens {
            for (position, item) in page.entries.enumerated() {
                guard case .game(let code) = item, let raw = desktops[code] else { throw SNESLibraryMenu.failure() }
                var edits = ["sortrawtitle": String(format: "%05d", position)]
                if let (rom, large, small) = custom[code] {
                    edits["exec"] = "/usr/bin/clover-canoe-shvc -rom " + SNESLibraryMenu.namespace + "/objects/" + rom + " --volume 100 -rollback-snapshot-period 600"
                    edits["path"] = "/var/lib/clover/profiles/0/" + code
                    edits["icon"] = SNESLibraryMenu.namespace + "/objects/" + large; edits["code"] = code
                    placements.append(.init(page: page.number, position: position, code: code, kind: "import", target: nil, rom: rom, artwork: large, smallArtwork: small))
                } else { placements.append(.init(page: page.number, position: position, code: code, kind: "stock", target: nil, rom: nil, artwork: nil, smallArtwork: nil)) }
                var rendered = try replace(raw, fields: edits)
                if custom[code] != nil { rendered = try SNESLibraryMenu.cloverDesktop(rendered) }
                files[String(format: "pages/%03d/%@/%@.desktop", page.number, code, code)] = rendered
            }
        }
        let references = try originals.entries.sorted { $0.code < $1.code }.map { entry -> SNESLibraryMenu.StockReference in
            guard let raw = desktops[entry.code] else { throw SNESLibraryMenu.failure() }
            return .init(code: entry.code, desktopSHA256: BackupManifest.digest(raw), romSHA256: entry.romSHA256, romBytes: entry.romBytes)
        }
        let description = SNESLibraryMenu.Manifest(version: 1, id: id, catalogSHA256: BackupManifest.digest(originals.raw), graph: graph, structure: structure,
            order: .title, objects: objects.keys.sorted().map { .init(name: $0, byteCount: objects[$0]!.count, sha256: BackupManifest.digest(objects[$0]!)) },
            files: files.keys.sorted().map { .init(path: $0, byteCount: files[$0]!.count, sha256: BackupManifest.digest(files[$0]!)) }, stock: references, placements: placements)
        let menu = try make(description, files: files, objects: objects); try menu.validate(); try validateStock(menu, originals: originals); return menu
    }
}
