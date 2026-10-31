import Foundation
import ImageIO
import SwiftHakchiCore

/// Immutable file preparation only; no console, activation or firmware capability.
struct SNESOneGameMenu:Sendable {
    static let namespace="/var/lib/swifthakchi/snes-v1"
    let id:UUID,code:String,title:String,files:[String:Data],manifest:Data
    let gameCount:Int,sourceROMSHA256:String,sourceArtworkSHA256:String,sourceMetadataSHA256:String
    var treeSHA256:String {BackupManifest.digest(manifest)}
    var consoleRoot:String {Self.namespace+"/menus/"+id.uuidString}
    var byteCount:Int {files.values.reduce(0){$0+$1.count}+manifest.count}
    var requiredFreeBytes:Int {
        files.values.reduce(0){$0+(($1.count+4095)/4096)*4096}+((manifest.count+4095)/4096)*4096+(gameCount+5)*4096+2*1024*1024
    }
    private init(id:UUID,code:String,title:String,files:[String:Data],manifest:Data,gameCount:Int,rom:Data,artwork:Data,metadata:Data) {
        self.id=id;self.code=code;self.title=title;self.files=files;self.manifest=manifest;self.gameCount=gameCount
        sourceROMSHA256=BackupManifest.digest(rom);sourceArtworkSHA256=BackupManifest.digest(artwork);sourceMetadataSHA256=BackupManifest.digest(metadata)
    }
    static func failure()->RecoveryProbeError {.refused("This game could not be prepared for the first SNES test. Your original ROM and library were not changed.")}
    static func fields(_ raw:Data) throws -> [String:String] {
        guard raw.count<=16384,let text=String(data:raw,encoding:.utf8),
              text.unicodeScalars.allSatisfy({$0.value==10 || $0.value==13 || $0.value>=32 && $0.value != 127}) else {throw failure()}
        var fields:[String:String]=[:]
        for row in text.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n") {
            guard !row.contains("\r") else {throw failure()}
            if row=="[Description]" {break}
            if row.isEmpty || row.hasPrefix("[") || row.hasPrefix("#") {continue}
            guard let at=row.firstIndex(of:"=") else {throw failure()}
            let key=String(row[..<at]).trimmingCharacters(in:.whitespaces).lowercased()
            guard !key.isEmpty,fields[key]==nil else {throw failure()}
            fields[key]=String(row[row.index(after:at)...]).trimmingCharacters(in:.whitespaces)
        }
        return fields
    }
    static func prepare(originals:SNESOriginalGamesFrame,code:String,metadata:Data,rom:Data,artwork:Data,id:UUID=UUID()) throws -> Self {
        try Task.checkCancellation()
        guard code.range(of:#"^CLV-U-[A-Z0-9]{5}$"#,options:.regularExpression) != nil,
              !originals.entries.isEmpty,originals.entries.count<35,!originals.entries.contains(where:{$0.code==code}) else {throw failure()}
        let fields=try fields(metadata)
        func text(_ key:String,_ fallback:String="",maximum:Int=256)throws->String {
            let value=fields[key] ?? fallback
            guard value.utf8.count<=maximum,!value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else {throw failure()};return value
        }
        let title=try text("name")
        guard !title.isEmpty else {throw failure()}
        func normalized(_ s:String)->String {s.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).filter{$0.isLetter || $0.isNumber}}
        var files:[String:Data]=[:]
        for original in originals.entries {
            guard let desktop=original.files.first(where:{$0.name==original.code+".desktop"}) else {throw failure()}
            let fields=try Self.fields(desktop.data)
            guard let name=fields["name"],!name.isEmpty,normalized(name) != normalized(title) else {throw failure()}
            // Stock desktops keep references to the original read-only ROM and artwork.
            files["games/"+original.code+"/"+desktop.name]=desktop.data
        }
        func integer(_ key:String,_ fallback:String,range:ClosedRange<Int>)throws->Int {
            let s=try text(key,fallback),n=Int(s)
            guard let n,String(n)==s,range.contains(n) else {throw failure()};return n
        }
        let players=try integer("players","1",range:1...2),simultaneous=try integer("simultaneous","0",range:0...1),saveCount=try integer("savecount","0",range:0...4)
        let date=try text("releasedate","1900-01-01")
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.calendar=Calendar(identifier:.gregorian);format.timeZone=TimeZone(secondsFromGMT:0);format.dateFormat="yyyy-MM-dd";format.isLenient=false
        guard date.range(of:#"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,options:.regularExpression) != nil,let parsed=format.date(from:date),format.string(from:parsed)==date else {throw failure()}
        let publisher=try text("x-swifthakchi-publisher",text("sortrawpublisher","UNKNOWN")),copyright=try text("copyright",maximum:1024),sort=try text("sortrawtitle",title.lowercased())
        let container=try SNESCanoeTrialImage(rom:rom)
        let png=try GameArtworkStore.png(from:artwork)
        guard let src=CGImageSourceCreateWithData(png as CFData,nil),let image=CGImageSourceCreateImageAtIndex(src,0,nil) else {throw failure()}
        func art(_ width:Int,_ height:Int)throws->Data {
            let ratio=min(1,min(Double(width)/Double(image.width),Double(height)/Double(image.height)))
            let w=max(1,Int(Double(image.width)*ratio)),h=max(1,Int(Double(image.height)*ratio))
            let data=resizeCoverArt(data:png,width:w,height:h)
            guard data.count<=262144,let source=CGImageSourceCreateWithData(data as CFData,nil),let checked=CGImageSourceCreateImageAtIndex(source,0,nil),checked.width==w,checked.height==h else {throw failure()};return data
        }
        let root=Self.namespace+"/menus/"+id.uuidString,base="games/"+code+"/"
        let desktop="""
        [Desktop Entry]
        Type=Application
        Exec=/usr/bin/clover-canoe-shvc -rom \(root)/\(base)\(code).sfrom --volume 100 -rollback-snapshot-period 600
        Path=/var/lib/clover/profiles/0/\(code)
        Name=\(title)
        Icon=\(root)/\(base)\(code).png

        [X-CLOVER Game]
        Code=\(code)
        TestID=0
        Status=
        ID=0
        Players=\(players)
        Simultaneous=\(simultaneous)
        ReleaseDate=\(date)
        SaveCount=\(saveCount)
        SortRawTitle=\(sort)
        SortRawPublisher=\(publisher)
        Copyright=\(copyright)
        MyPlayDemoTime=45

        """
        files[base+code+".desktop"]=Data(desktop.utf8);files[base+code+".sfrom"]=container.data
        files[base+code+".png"]=try art(228,204);files[base+code+"_small.png"]=try art(40,40)
        guard files.count<=128,files.values.reduce(0,{$0+$1.count})<=8*1024*1024 else {throw failure()}
        let manifest=Data(("SWIFTHAKCHI_SNES_MENU_V1\n"+files.keys.sorted().map {BackupManifest.digest(files[$0]!) + " " + String(files[$0]!.count) + " " + $0 + "\n"}.joined()).utf8)
        guard manifest.count<=32768 else {throw failure()}
        return .init(id:id,code:code,title:title,files:files,manifest:manifest,gameCount:originals.entries.count+1,rom:rom,artwork:artwork,metadata:metadata)
    }
}
