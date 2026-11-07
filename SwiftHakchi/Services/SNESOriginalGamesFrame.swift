import Foundation
import SwiftHakchiCore

/// Inert original metadata/art and fixed-size ROM headers, never ROM payloads or write authority.
struct SNESOriginalGamesFrame:Sendable {
    static let maximumSize=8*1024*1024
    struct File:Sendable {let name:String,data:Data}
    struct Entry:Sendable {let code:String,files:[File],romName:String,romBytes:Int,romSHA256:String,headers:Data}
    let raw:Data,launcher:Data,entries:[Entry]
    let hwid:String
    func gameTitle(for code: String) -> String? {
        guard let entry = entries.first(where: { $0.code == code }),
              let desktop = entry.files.first(where: { $0.name == code + ".desktop" }),
              let title = try? SNESOneGameMenu.fields(desktop.data)["name"], !title.isEmpty else { return nil }
        return title
    }
    static func failure()->RecoveryProbeError {
        .refused("The original SNES game information could not be verified. No games were changed.")
    }
    init(_ raw:Data,binding:SNESRuntimeBinding,challenge:UUID)throws {
        try binding.validate()
        guard raw.count<=Self.maximumSize else {throw Self.failure()}
        let bytes=Array(raw);var cursor=0
        func line()throws->String {
            guard cursor<bytes.count,let end=bytes[cursor..<min(bytes.count,cursor+384)].firstIndex(of:10),
                  bytes[cursor..<end].allSatisfy({(32...126).contains($0)}) else {throw Self.failure()}
            let s=String(decoding:bytes[cursor..<end],as:UTF8.self);cursor=end+1;return s
        }
        func number(_ s:String,maximum:Int,minimum:Int=1)throws->Int {
            guard let n=Int(s),String(n)==s,(minimum...maximum).contains(n) else {throw Self.failure()};return n
        }
        func blob(_ n:Int,digest:String)throws->Data {
            guard SNESDataSnapshotChunk.isDigest(digest),n<bytes.count-cursor else {throw Self.failure()}
            let value=Data(bytes[cursor..<cursor+n]);cursor+=n
            guard bytes[cursor]==10,BackupManifest.digest(value)==digest else {throw Self.failure()};cursor+=1;return value
        }
        guard try line()=="SWIFTHAKCHI_SNES_ORIGINAL_GAMES_V1 "+challenge.uuidString,
              try line()=="HWID "+binding.expectedHWID else {throw Self.failure()}
        let wrapper=try line().components(separatedBy:" ")
        guard wrapper.count==3,wrapper[0]=="WRAPPER" else {throw Self.failure()}
        let launcher=try blob(number(wrapper[1],maximum:16384),digest:wrapper[2])
        var entries:[Entry]=[],previousCode=""
        while true {
            let row=try line().components(separatedBy:" ")
            if row.count==2,row[0]=="END" {
                guard try number(row[1],maximum:48)==entries.count,cursor==bytes.count else {throw Self.failure()};break
            }
            guard row.count==2,row[0]=="GAME",entries.count<48 else {throw Self.failure()}
            let code=row[1]
            guard code.range(of:#"^CLV-P-[A-Z0-9]{5}$"#,options:.regularExpression) != nil,code>previousCode else {throw Self.failure()}
            previousCode=code
            var files:[File]=[],previousName="",pngCount=0,desktopCount=0,next=try line().components(separatedBy:" ")
            while next.first=="FILE" {
                guard next.count==4,files.count<5 else {throw Self.failure()}
                let name=next[1],desktop=name==code+".desktop"
                guard name.utf8.count<=128,name>previousName,name.hasPrefix(code),
                      name.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,46,95].contains($0)}),
                      desktop || name.hasSuffix(".png") else {throw Self.failure()}
                previousName=name
                let size=try number(next[2],maximum:desktop ? 8192:262144,minimum:desktop ? 1:8)
                let data=try blob(size,digest:next[3])
                if desktop {desktopCount+=1} else {
                    pngCount+=1;guard pngCount<=4,data.starts(with:[137,80,78,71,13,10,26,10]) else {throw Self.failure()}
                }
                files.append(.init(name:name,data:data));next=try line().components(separatedBy:" ")
            }
            guard desktopCount==1,pngCount>=1,next.count==5,next[0]=="ROM",next[1]==code+".sfrom",
                  SNESDataSnapshotChunk.isDigest(next[3]) else {throw Self.failure()}
            let romBytes=try number(next[2],maximum:16*1024*1024,minimum:96),headers=try blob(96,digest:next[4])
            guard try line()=="END_GAME" else {throw Self.failure()}
            entries.append(.init(code:code,files:files,romName:next[1],romBytes:romBytes,romSHA256:next[3],headers:headers))
        }
        self.raw=Data(raw);self.launcher=launcher;self.entries=entries;self.hwid=binding.expectedHWID
    }
}
