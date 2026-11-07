import Foundation
import CryptoKit

enum GameGenieSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case nes, snes, genesis
    var id:String {rawValue}
    var name:String {switch self {case .nes:return "NES";case .snes:return "SNES";case .genesis:return "Genesis"}}
    var indexURL:URL {URL(string:"https://gamegenie.com/cheats/gamegenie/\(rawValue)/index.html")!}
    init?(console:ConsoleType) {
        if console.isNES {self = .nes} else if console.isSNES {self = .snes}
        else if console == .megaDrive {self = .genesis} else {return nil}
    }
    func accepts(_ code:String)->Bool {
        switch self {
        case .nes:return GameGenieNES.decode(code) != nil
        case .snes:return code.range(of:"^[0-9A-F]{4}-[0-9A-F]{4}$",options:.regularExpression) != nil
        case .genesis:return code.range(of:"^[ABCDEFGHJKLMNPRSTVWXYZ0123456789]{4}-[ABCDEFGHJKLMNPRSTVWXYZ0123456789]{4}$",options:.regularExpression) != nil
        }
    }
}
struct GameGenieOfflineCatalog: Codable, Sendable {
    struct Entry:Codable,Identifiable,Equatable,Sendable {
        var game:String, codes:[String], title:String
        var context:String="", alternatives:[[String]]=[], dependencies:[String]=[],notes:[String]=[],sources:[String]=[],reviewReasons:[String]=[]
        var id:String {
            let identity=[Self.gameKey(game),context,codes.map{$0.uppercased()}.joined(separator:"+"),dependencies.joined(separator:"+"),alternatives.map{$0.joined(separator:"+")}.joined(separator:"/"),codes.isEmpty && alternatives.isEmpty ? title:""]
            return GameGenieOfflineCatalog.digest(try! JSONEncoder().encode(identity))
        }
        static func gameKey(_ text:String)->String {
            text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)}.map(String.init).joined()
        }
        func selectableCodes(system:GameGenieSystem)->[String]? {
            let result=dependencies+codes
            guard reviewReasons.isEmpty,alternatives.isEmpty,!codes.isEmpty,result.count<=32,result.allSatisfy({system.accepts($0)}) else{return nil}
            return result.reduce(into:[]){if !$0.contains($1) {$0.append($1)}}
        }
    }
    struct Coverage:Codable,Equatable,Sendable {
        var discovered=0,fetched=0,failedURLs:[String]=[],reviewEntries=0
        var complete:Bool {discovered>0 && fetched==discovered && failedURLs.isEmpty && reviewEntries==0}
    }
    var version=2
    var system:GameGenieSystem
    var effects:[Entry]
    var sources:[String]=[]
    var notices:[String]=[]
    var coverage=Coverage()
    static let maximumBytes=16*1024*1024
    static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func decode(_ data:Data)throws->Self {
        guard data.count<=maximumBytes else {throw GameGenieCatalog.CatalogError.invalid}
        return try JSONDecoder().decode(Self.self,from:data).validated()
    }
    func encoded()throws->Data {
        _=try validated();let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(self);guard data.count<=Self.maximumBytes else {throw GameGenieCatalog.CatalogError.invalid};return data
    }
    func validated()throws->Self {
        guard version==2,effects.count<=40000,sources.count<=2048,notices.count<=64,coverage.discovered>=0,coverage.discovered<=1500,
              coverage.fetched>=0,coverage.fetched<=coverage.discovered,coverage.failedURLs.count<=1500,
              coverage.reviewEntries>=0,coverage.reviewEntries<=40000 else {throw GameGenieCatalog.CatalogError.invalid}
        func bounded(_ values:[String],_ count:Int,_ length:Int)->Bool {values.count<=count && values.allSatisfy{$0.utf8.count<=length && !$0.contains("\0")}}
        guard bounded(sources,2048,4096),bounded(notices,64,32768),bounded(coverage.failedURLs,1500,4096) else {throw GameGenieCatalog.CatalogError.invalid}
        for row in effects {
            guard !row.game.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,row.game.count<=256,!row.title.isEmpty,row.title.count<=8192,row.context.count<=4096,
                  bounded(row.codes,32,32),bounded(row.dependencies,32,32),row.alternatives.count<=32,row.alternatives.allSatisfy({bounded($0,32,32)}),
                  bounded(row.notes,256,8192),bounded(row.sources,64,4096),bounded(row.reviewReasons,32,1024) else {throw GameGenieCatalog.CatalogError.invalid}
            if row.reviewReasons.isEmpty && row.alternatives.isEmpty && !row.codes.isEmpty {guard row.selectableCodes(system:system) != nil else {throw GameGenieCatalog.CatalogError.invalid}}
        }
        guard Set(effects.map(\.id)).count==effects.count else {throw GameGenieCatalog.CatalogError.invalid}
        return self
    }
    // Search aliases never alter effect identity or merge different games/versions.
    func searchKey(_ title:String)->String {
        let key=Entry.gameKey(title)
        if system == .snes {
            switch key {
            case "aliensvspredator": return "alienvspredator"
            case "thelegendofzeldaalinktothepast", "legendofzeldathealinktothepast", "legendofzeldaalinktothepast": return "legendofzelda"
            case "gradiusiii": return "gradius3"
            case "contraiiithealienwars": return "contra3thealienwars"
            case "mortalkombatii": return "mortalkombat2"
            case "doubledragonvtheshadowfalls": return "doubledragon5"
            case "robocopversustheterminator": return "robocopvstheterminator"
            case "superstarwarstheempirestrikesback": return "supertheempirestrikesback"
            case "donkeykongcountry2diddyskongquest": return "donkeykongcountry2"
            case "superstarwarsreturnofthejedi": return "superreturnofthejedi"
            case "t2thearcadegame": return "terminator2thearcadegame"
            default: break
            }
        }
        return key
    }
    func searchGames(_ query:String)->[String] {
        let key=searchKey(query),literal=Entry.gameKey(query)
        return Set(effects.map(\.game)).filter{key.isEmpty || searchKey($0).contains(key) || Entry.gameKey($0).contains(literal)}.sorted{$0.localizedStandardCompare($1) == .orderedAscending}
    }
    func entries(game:String)->[Entry] {effects.filter{$0.game==game}}
    func merged(with other:Self)throws->Self {
        guard system==other.system else {throw GameGenieCatalog.CatalogError.invalid}
        var result=self,index=Dictionary(uniqueKeysWithValues:effects.enumerated().map{($0.element.id,$0.offset)})
        func union(_ a:[String],_ b:[String])->[String] {b.reduce(into:a){if !$0.contains($1) {$0.append($1)}}}
        for entry in other.effects {
            if let i=index[entry.id] {
                var old=result.effects[i]
                old.notes=union(old.notes,entry.notes+(old.title==entry.title ? []:["Also described as: "+entry.title]))
                old.sources=union(old.sources,entry.sources);old.reviewReasons=union(old.reviewReasons,entry.reviewReasons);result.effects[i]=old
            } else {index[entry.id]=result.effects.count;result.effects.append(entry)}
        }
        result.sources=union(sources,other.sources);result.notices=union(notices,other.notices)
        result.coverage=other.coverage.discovered>0 ? other.coverage:coverage
        result.coverage.reviewEntries=result.effects.filter{!$0.reviewReasons.isEmpty}.count
        return try result.validated()
    }
    static func migrating(_ old:GameGenieCatalog)throws->Self {
        let result=Self(system:.nes,effects:[],sources:[old.workbookName+" · SHA256 "+old.workbookSHA256])
        let notes=Dictionary(grouping:old.rows,by:{$0.game}).mapValues{$0.filter{($0.effect ?? "").isEmpty && !$0.rawCodes.isEmpty}.map(\.rawCodes)}
        var entries:[Entry]=[]
        for row in old.rows where !(row.effect ?? "").isEmpty {
            let codes=row.validCodes ?? []
            let entry=Entry(game:row.game,codes:codes,title:row.effect!,notes:(notes[row.game] ?? [])+(codes.isEmpty ? [row.rawCodes]:[]),sources:[old.workbookName+" · NES row\(row.row) · "+(row.source ?? "Source unspecified")],reviewReasons:codes.isEmpty ? ["Review original codes or version alternatives"]:[])
            entries.append(entry)
        }
        return try result.merged(with:Self(system:.nes,effects:entries))
    }
    func effect(from entry:Entry)throws->GameGenieEffect {
        guard effects.contains(entry),let codes=entry.selectableCodes(system:system) else {throw GameGenieCatalog.CatalogError.reviewRequired}
        return GameGenieEffect(name:entry.title,codes:codes,enabled:false,source:entry.sources.joined(separator:"\n"),notes:entry.notes)
    }
}

/// Suggestions are title matches, never evidence that a particular ROM revision matches.
enum GameGenieSuggestions {
    static func needsReview(gameNames: [String], system: GameGenieSystem,
                            catalog: GameGenieOfflineCatalog) -> Bool {
        guard catalog.system == system else { return false }
        let titles = Set(gameNames.map { catalog.searchKey($0) }.filter { !$0.isEmpty })
        return catalog.effects.contains { titles.contains(catalog.searchKey($0.game)) && $0.selectableCodes(system: system) == nil }
    }
    static func rows(gameNames: [String], system: GameGenieSystem,
                     catalog: GameGenieOfflineCatalog, existing: [GameGenieEffect]) -> [GameGenieOfflineCatalog.Entry] {
        guard catalog.system == system else { return [] }
        let titles = Set(gameNames.map { catalog.searchKey($0) }.filter { !$0.isEmpty })
        let selected = existing.map { Set($0.codes.map { $0.uppercased() }) }
        return catalog.effects.filter { row in
            guard titles.contains(catalog.searchKey(row.game)),
                  let codes = row.selectableCodes(system: system) else { return false }
            return !selected.contains(Set(codes.map { $0.uppercased() }))
        }
    }
}
