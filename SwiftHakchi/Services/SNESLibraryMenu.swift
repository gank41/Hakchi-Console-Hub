import Foundation
import ImageIO
import SwiftHakchiCore

/// Inert multi-game material. Publishing needs a separately checked startup and transaction.
struct SNESLibraryMenu: Sendable {
    static let namespace = "/var/lib/swifthakchi/snes-v2"
    struct NavigationArtwork: Sendable { let more: Data, back: Data, custom: [String: Data] }
    struct FileRecord: Codable, Equatable, Sendable { let path: String, byteCount: Int, sha256: String }
    struct StockReference: Codable, Equatable, Sendable {
        let code: String, desktopSHA256: String, romSHA256: String, romBytes: Int
    }
    struct Placement: Codable, Equatable, Sendable {
        let page: Int, position: Int, code: String, kind: String, target: Int?
        let rom: String?, artwork: String?, smallArtwork: String?
    }
    struct Manifest: Codable, Equatable, Sendable {
        let version: Int, id: UUID, catalogSHA256: String
        let graph: ConsoleMenuGraph, structure: ConsoleStructure, order: ConsoleMenuOrder
        let objects: [SNESLibraryObjects.Record], files: [FileRecord], stock: [StockReference], placements: [Placement]
    }
    let description: Manifest, files: [String: Data], objects: [String: Data]
    let sources: [SNESLibrarySourceFile], manifest: Data, sourceSHA256: String
    var id: UUID { description.id }
    var graph: ConsoleMenuGraph { description.graph }
    var objectRecords: [SNESLibraryObjects.Record] { description.objects }
    var consoleRoot: String { Self.namespace + "/menus/" + id.uuidString }
    static func failure() -> SyncPlanError { .invalidInput("The SNES game review changed or contains unsupported menu information. Prepare a new review.") }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func fileLimit(_ path:String,version:Int) throws -> Int {
        guard [1,2,3,4].contains(version) else {throw failure()}
        let parts=path.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard parts.count==4,parts[0]=="pages",parts[1].range(of:#"^[0-9]{3}$"#,options:.regularExpression) != nil,
              let page=Int(parts[1]),page<32,
              parts[2].range(of:#"^CLV-[PUS]-[A-Z0-9]{5}$"#,options:.regularExpression) != nil else {throw failure()}
        if parts[3]==parts[2]+".desktop" {return 16384}
        guard [2,4].contains(version),!parts[2].hasPrefix("CLV-P-"),
              parts[3]==parts[2]+".png" || parts[3]==parts[2]+"_small.png" else {throw failure()}
        return 262144
    }

    // Clover emits an apostrophe as \39 in its Lua game list. A following
    // digit becomes part of that escape (for example, Madden NFL '94 -> \3994).
    // Use a typographic apostrophe only at this console-export boundary; the
    // user's metadata and ROM stay unchanged, as do frozen recovery menus.
    private static func cloverText(_ value: String) -> String {
        value.replacingOccurrences(of: "'(?=[0-9])", with: "’", options: .regularExpression)
    }

    /// Only for a newly prepared imported menu; never rewrite a saved recovery package.
    static func cloverDesktop(_ data: Data) throws -> Data {
        _ = try SNESOneGameMenu.fields(data)
        guard let text = String(data: data, encoding: .utf8) else { throw failure() }
        let lines = try text.components(separatedBy: "\n").map { line -> String in
            guard let equal = line.firstIndex(of: "=") else { return line }
            let key = String(line[..<equal]).lowercased()
            guard ["name", "sortrawtitle", "sortrawpublisher", "copyright"].contains(key) else { return line }
            let value = cloverText(String(line[line.index(after: equal)...]))
            guard safeText(value, maximum: key == "copyright" ? 1024 : 256) else { throw failure() }
            return String(line[...equal]) + value
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func safeText(_ value: String, maximum: Int = 256) -> Bool {
        value.utf8.count <= maximum && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    func validate() throws {
        let m = description
        guard [1,2,3,4].contains(m.version), m.graph.screens.count <= 32, m.objects.count <= 1024, m.files.count <= 2048,
              sources.count <= 768, manifest.count <= 1024 * 1024, SNESDataSnapshotChunk.isDigest(m.catalogSHA256),
              try manifest == Self.encode(m), sourceSHA256 == BackupManifest.digest(try Self.encode(sources)),
              m.objects.map(\.name) == m.objects.map(\.name).sorted(), Set(m.objects.map(\.name)) == Set(objects.keys),
              m.files.map(\.path) == m.files.map(\.path).sorted(), Set(m.files.map(\.path)) == Set(files.keys),
              Set(m.objects.map(\.name)).count == m.objects.count, Set(m.files.map(\.path)).count == m.files.count,
              Set(m.stock.map(\.code)).count == m.stock.count else { throw Self.failure() }
        try m.structure.validate()
        guard m.graph.maximumGamesPerPage == m.structure.maximumGamesPerPage.rawValue else { throw Self.failure() }
        try m.graph.validate(selectedCodes: Set(m.graph.screens.flatMap(\.gameCodes)))
        guard m.graph.screens.flatMap(\.gameCodes).count <= 304,
              m.graph.maximumGamesPerPage == m.structure.maximumGamesPerPage.rawValue,
              m.graph.screens.allSatisfy({ $0.backPosition == m.structure.backPosition }),
              m.structure.mode == .automatic || m.structure.mode == .stockRootAutomatic || m.structure.mode == m.graph.resolvedMode else { throw Self.failure() }
        var bytes = 0
        for record in m.objects {
            try record.validate(allowCompatibility: [3,4].contains(m.version))
            guard let data = objects[record.name], data.count == record.byteCount, BackupManifest.digest(data) == record.sha256 else { throw Self.failure() }
            bytes += data.count; guard bytes <= 128 * 1024 * 1024 else { throw Self.failure() }
        }
        for stock in m.stock {
            guard stock.code.range(of: #"^CLV-P-[A-Z0-9]{5}$"#, options: .regularExpression) != nil,
                  SNESDataSnapshotChunk.isDigest(stock.desktopSHA256), SNESDataSnapshotChunk.isDigest(stock.romSHA256),
                  (96...16 * 1024 * 1024).contains(stock.romBytes) else { throw Self.failure() }
        }
        let stockCodes = Set(m.stock.map(\.code)), records = Dictionary(uniqueKeysWithValues: m.files.map { ($0.path, $0) })
        var paths = Set<String>(), referenced = Set<String>(), selectedStock = Set<String>(), index = 0
        for page in m.graph.screens {
            for (position, entry) in page.entries.enumerated() {
                guard index < m.placements.count else { throw Self.failure() }
                let placement = m.placements[index]; index += 1
                guard placement.page == page.number, placement.position == position else { throw Self.failure() }
                let code = placement.code, path = String(format: "pages/%03d/%@/%@.desktop", page.number, code, code)
                guard paths.insert(path).inserted, let record = records[path], let data = files[path], (1...16384).contains(record.byteCount),
                      data.count == record.byteCount, BackupManifest.digest(data) == record.sha256 else { throw Self.failure() }
                let fields = try SNESOneGameMenu.fields(data)
                guard let title = fields["name"], !title.isEmpty, Self.safeText(title), fields["sortrawtitle"] == String(format: "%05d", position) else { throw Self.failure() }
                switch entry {
                case .game(let expected):
                    guard code == expected, placement.target == nil else { throw Self.failure() }
                    if stockCodes.contains(code) {
                        guard placement.kind == "stock", placement.rom == nil, placement.artwork == nil, placement.smallArtwork == nil else { throw Self.failure() }
                        selectedStock.insert(code); continue
                    }
                    guard code.range(of: #"^CLV-U-[A-Z0-9]{5}$"#, options: .regularExpression) != nil,
                          let rom = placement.rom, objects[rom] != nil,
                          fields["path"] == "/var/lib/clover/profiles/0/" + code else { throw Self.failure() }
                    if placement.kind == "import" {
                        guard rom.hasSuffix(".sfrom"),
                              fields["exec"] == "/usr/bin/clover-canoe-shvc -rom " + Self.namespace + "/objects/" + rom + " --volume 100 -rollback-snapshot-period 600" else { throw Self.failure() }
                    } else {
                        // Versions 3 and 4 remain blocked from transfer until the
                        // supervisor and recovery workflow are complete.
                        guard [3,4].contains(m.version), placement.kind == "compat",
                              rom.range(of: #"^[0-9a-f]{64}\.(sfc|smc)$"#, options: .regularExpression) != nil,
                              fields["exec"] == "/mnt/swifthakchi/hc-snes-superv --game " + code + " --rom " + Self.namespace + "/objects/" + rom else { throw Self.failure() }
                    }
                    referenced.insert(rom)
                case .link(let target):
                    guard placement.kind == "link", placement.target == target, placement.rom == nil,
                          code == String(format: "CLV-S-%05d", target),
                          fields["exec"] == String(format: "/mnt/swifthakchi/menu-change %03d", target),
                          fields["path"] == "/var/lib/clover/profiles/0/FOLDER",
                          title == page.links.first(where: { $0.target == target })?.title else { throw Self.failure() }
                }
                guard let large = placement.artwork, let small = placement.smallArtwork,
                      small == large.replacingOccurrences(of: ".png", with: "_small.png"),
                      fields["code"] == code else { throw Self.failure() }
                let a:Data,b:Data
                if m.version==1 || m.version==3 {
                    guard let largeData=objects[large],let smallData=objects[small],
                          fields["icon"]==Self.namespace+"/objects/"+large else {throw Self.failure()}
                    a=largeData;b=smallData
                    referenced.formUnion([large,small])
                } else {
                    let prefix=String(format:"pages/%03d/%@/%@",page.number,code,code)
                    let largePath=prefix+".png",smallPath=prefix+"_small.png"
                    guard fields["icon"]==consoleRoot+"/"+largePath else {throw Self.failure()}
                    func imageFile(_ path:String) throws -> Data {
                        guard paths.insert(path).inserted,let record=records[path],let data=files[path],
                              (8...262144).contains(record.byteCount),data.count==record.byteCount,
                              BackupManifest.digest(data)==record.sha256 else {throw Self.failure()}
                        return data
                    }
                    a=try imageFile(largePath);b=try imageFile(smallPath)
                }
                let address = BackupManifest.digest(Data((BackupManifest.digest(a) + ":" + BackupManifest.digest(b)).utf8))
                guard large == address + ".png" else { throw Self.failure() }
                for (image, width, height) in [(a, 228, 204), (b, 40, 40)] {
                    guard let source = CGImageSourceCreateWithData(image as CFData, nil), CGImageSourceGetCount(source) == 1,
                          let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int,
                          (1...width).contains(w), (1...height).contains(h) else { throw Self.failure() }
                }
            }
        }
        guard bytes+([2,4].contains(m.version) ? files.values.reduce(0,{$0+$1.count}):0)<=128*1024*1024 else {throw Self.failure()}
        guard index == m.placements.count, paths == Set(files.keys), referenced == Set(objects.keys), selectedStock == stockCodes else { throw Self.failure() }
    }

    /// Match the original SNES UI: thumbnail directory plus CODE_small.png.
    /// ROMs stay in the immutable shared pool. PNGs occur only as menu-local files.
    func withNativeArtwork() throws -> Self {
        guard [1,2,3,4].contains(description.version) else { throw Self.failure() }
        try validate()
        if [2,4].contains(description.version) {return self}
        var nativeFiles=files
        for item in description.placements where item.kind != "stock" {
            let prefix=String(format:"pages/%03d/%@/%@",item.page,item.code,item.code)
            guard let large=item.artwork,let small=item.smallArtwork,
                  let image=objects[large],let thumbnail=objects[small],
                  let raw=files[prefix+".desktop"],let text=String(data:raw,encoding:.utf8) else {throw Self.failure()}
            let old="Icon="+Self.namespace+"/objects/"+large,new="Icon="+consoleRoot+"/"+prefix+".png"
            let lines=text.components(separatedBy:"\n")
            guard lines.filter({$0==old}).count==1 else {throw Self.failure()}
            nativeFiles[prefix+".desktop"]=Data(lines.map {$0==old ? new:$0}.joined(separator:"\n").utf8)
            nativeFiles[prefix+".png"]=image;nativeFiles[prefix+"_small.png"]=thumbnail
        }
        let romNames=Set(description.placements.compactMap(\.rom))
        let nativeObjects=objects.filter {romNames.contains($0.key)}
        let d=description
        let next=Manifest(version:d.version==3 ? 4:2,id:d.id,catalogSHA256:d.catalogSHA256,graph:d.graph,structure:d.structure,order:d.order,
            objects:d.objects.filter {romNames.contains($0.name)},
            files:nativeFiles.keys.sorted().map {.init(path:$0,byteCount:nativeFiles[$0]!.count,sha256:BackupManifest.digest(nativeFiles[$0]!))},
            stock:d.stock,placements:d.placements)
        let value=Self(description:next,files:nativeFiles,objects:nativeObjects,sources:sources,manifest:try Self.encode(next),sourceSHA256:sourceSHA256)
        try value.validate();return value
    }

    @MainActor static func originalGames(originals: SNESOriginalGamesFrame, id: UUID = UUID()) throws -> Self {
        let review = try SNESLibraryCompatibility.review(games: [], originals: originals)
        return try prepare(review: review, originals: originals, selected: [], decisions: [:], order: .title,
            structure: .init(mode: .flat, maximumGamesPerPage: .thirtyFive), artwork: .init(more: Data(), back: Data(), custom: [:]), id: id)
    }
    @MainActor static func prepare(review: SNESLibraryCompatibility, originals: SNESOriginalGamesFrame,
        selected: Set<String>, decisions: [String: SNESLibraryCompatibility.Resolution], order: ConsoleMenuOrder,
        structure: ConsoleStructure, artwork: NavigationArtwork, id: UUID = UUID(), cache: SNESLibraryObjectCache? = nil) throws -> Self {
        let resolved = try review.resolvedCodes(selected: selected, decisions: decisions)
        guard review.stockCodes == Set(originals.entries.map(\.code)), resolved.count <= 304 else { throw failure() }
        let content = try cache?.content(review: review, resolvedCodes: resolved) ?? SNESLibraryObjects.prepare(review: review, resolvedCodes: resolved)
        return try build(review: review, originals: originals, resolved: resolved, content: content, compatibilityCodes: [],
                         order: order, structure: structure, artwork: artwork, id: id)
    }
    /// Shared builder; compatibility entries are inert Mac-only version 3.
    @MainActor static func build(review: SNESLibraryCompatibility, originals: SNESOriginalGamesFrame,
        resolved: Set<String>, content: SNESLibraryObjects, compatibilityCodes: Set<String>, order: ConsoleMenuOrder,
        structure: ConsoleStructure, artwork: NavigationArtwork, id: UUID) throws -> Self {
        guard review.stockCodes == Set(originals.entries.map(\.code)), resolved.count <= 304,
              Set(content.items.keys) == resolved.subtracting(review.stockCodes),
              compatibilityCodes.isSubset(of: Set(content.items.keys)) else { throw failure() }
        var games = content.items.values.map(\.game), stocks: [String: (SNESOriginalGamesFrame.Entry, Data)] = [:]
        for entry in originals.entries where resolved.contains(entry.code) {
            guard let desktop = entry.files.first(where: { $0.name == entry.code + ".desktop" }) else { throw failure() }
            let fields = try SNESOneGameMenu.fields(desktop.data)
            guard let title = fields["name"], !title.isEmpty, safeText(title) else { throw failure() }
            stocks[entry.code] = (entry, desktop.data)
            games.append(Game(code: entry.code, desktopContent: String(decoding: desktop.data, as: UTF8.self), consoleType: .snesUsa, source: .stock))
        }
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: Set(stocks.keys), order: order, structure: structure)
        guard graph.screens.count <= 32 else { throw failure() }
        var files: [String: Data] = [:], objects = content.objects, placements: [Placement] = []
        func desktop(_ code: String, _ page: Int, _ data: Data) throws {
            guard data.count <= 16384 else { throw failure() }
            files[String(format: "pages/%03d/%@/%@.desktop", page, code, code)] = data
        }
        func rankedStock(_ raw: Data, _ rank: String) throws -> Data {
            _ = try SNESOneGameMenu.fields(raw)
            guard let text = String(data: raw, encoding: .utf8) else { throw failure() }
            var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            while lines.last == "" { lines.removeLast() }
            if let index = lines.firstIndex(where: { $0.lowercased().hasPrefix("sortrawtitle=") }) { lines[index] = "SortRawTitle=" + rank }
            else { lines += ["[X-CLOVER Game]", "SortRawTitle=" + rank] }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        let root = Self.namespace + "/objects/"
        for page in graph.screens {
            for (position, entry) in page.entries.enumerated() {
                let rank = String(format: "%05d", position)
                switch entry {
                case .game(let code):
                    if let stock = stocks[code] {
                        try desktop(code, page.number, rankedStock(stock.1, rank))
                        placements.append(.init(page: page.number, position: position, code: code, kind: "stock", target: nil, rom: nil, artwork: nil, smallArtwork: nil))
                        continue
                    }
                    guard let item = content.items[code] else { throw failure() }
                    let game = item.game
                    let title = cloverText(game.name), publisher = cloverText(game.publisher), copyright = cloverText(game.copyright)
                    guard !title.isEmpty, safeText(title), safeText(publisher), safeText(copyright, maximum: 1024),
                          (1...5).contains(game.players), (0...4).contains(game.saveCount) else { throw failure() }
                    let date: String
                    if game.releaseDate.isEmpty { date = "1900-01-01" }
                    else {
                        let value = game.releaseDate.count == 4 ? game.releaseDate + "-01-01" : game.releaseDate
                        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
                        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
                              let parsed = formatter.date(from: value), formatter.string(from: parsed) == value else { throw failure() }
                        date = value
                    }
                    let isCompatibility = compatibilityCodes.contains(code)
                    let executable = isCompatibility ? "/mnt/swifthakchi/hc-snes-superv --game \(code) --rom \(root)\(item.rom)" : "/usr/bin/clover-canoe-shvc -rom \(root)\(item.rom) --volume 100 -rollback-snapshot-period 600"
                    let value = """
                    [Desktop Entry]
                    Type=Application
                    Exec=\(executable)
                    Path=/var/lib/clover/profiles/0/\(code)
                    Name=\(title)
                    Icon=\(root)\(item.artwork)
                    [X-CLOVER Game]
                    Code=\(code)
                    TestID=0
                    Status=
                    ID=0
                    Players=\(game.players)
                    Simultaneous=\(game.simultaneous ? 1 : 0)
                    ReleaseDate=\(date)
                    SaveCount=\(max(game.saveCount, item.saveCount))
                    SortRawTitle=\(rank)
                    SortRawPublisher=\(publisher)
                    Copyright=\(copyright)
                    MyPlayDemoTime=45

                    """
                    try desktop(code, page.number, Data(value.utf8))
                    placements.append(.init(page: page.number, position: position, code: code, kind: isCompatibility ? "compat" : "import", target: nil,
                                            rom: item.rom, artwork: item.artwork, smallArtwork: item.smallArtwork))
                case .link(let target):
                    guard let link = page.links.first(where: { $0.target == target }) else { throw failure() }
                    let image: Data
                    if link.role == .back { image = artwork.back }
                    else if structure.folderArt == .custom, let key = link.artKey {
                        guard let custom = artwork.custom[key] else { throw failure() }; image = custom
                    } else if structure.folderArt == .letterTiles {
                        image = try ConsoleFolderArtwork.previewData(for: link, style: .letterTiles, artworkDirectory: nil)
                    } else { image = artwork.more }
                    let pair = try SNESLibraryObjects.images(from: image)
                    let names = SNESLibraryObjects.storeImages(pair, in: &objects), code = link.consoleCode
                    let value = """
                    [Desktop Entry]
                    Type=Application
                    Exec=/mnt/swifthakchi/menu-change \(String(format: "%03d", target))
                    Path=/var/lib/clover/profiles/0/FOLDER
                    Name=\(link.title)
                    Icon=\(root)\(names.large)
                    [X-CLOVER Game]
                    Code=\(code)
                    TestID=777
                    ID=0
                    Players=1
                    Simultaneous=0
                    ReleaseDate=1900-01-01
                    SaveCount=0
                    SortRawTitle=\(rank)
                    SortRawPublisher=ZZZZZZZZZZ

                    """
                    try desktop(code, page.number, Data(value.utf8))
                    placements.append(.init(page: page.number, position: position, code: code, kind: "link", target: target,
                                            rom: nil, artwork: names.large, smallArtwork: names.small))
                }
            }
        }
        guard files.count <= 2048, objects.count <= 1024, objects.values.reduce(0, { $0 + $1.count }) <= 128 * 1024 * 1024 else { throw failure() }
        let records = objects.keys.sorted().map { SNESLibraryObjects.Record(name: $0, byteCount: objects[$0]!.count, sha256: BackupManifest.digest(objects[$0]!)) }
        let version = compatibilityCodes.isEmpty ? 1 : 3
        for record in records { try record.validate(allowCompatibility: version == 3) }
        let description = Manifest(version: version, id: id, catalogSHA256: BackupManifest.digest(originals.raw), graph: graph, structure: structure, order: order,
            objects: records, files: files.keys.sorted().map { .init(path: $0, byteCount: files[$0]!.count, sha256: BackupManifest.digest(files[$0]!)) },
            stock: stocks.keys.sorted().map { let value = stocks[$0]!; return .init(code: $0, desktopSHA256: BackupManifest.digest(value.1), romSHA256: value.0.romSHA256, romBytes: value.0.romBytes) }, placements: placements)
        let manifest = try encode(description)
        guard manifest.count <= 1024 * 1024 else { throw failure() }
        let value = Self(description: description, files: files, objects: objects, sources: content.sources, manifest: manifest,
                         sourceSHA256: BackupManifest.digest(try encode(content.sources)))
        try value.validate(); return value
    }
}
