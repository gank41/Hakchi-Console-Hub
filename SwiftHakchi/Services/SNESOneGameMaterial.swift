import Foundation
import SwiftHakchiCore

struct SNESOneGamePaths:Codable,Sendable {
    let firmwareOperation:String,firmwareReviewSHA256:String,catalogDirectory:String,gameDirectory:String,romFilename:String,backupsDirectory:String
    func validate()throws {
        guard [firmwareOperation,catalogDirectory,gameDirectory,backupsDirectory].allSatisfy({$0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096}),
              SNESDataSnapshotChunk.isDigest(firmwareReviewSHA256),!romFilename.isEmpty,romFilename.utf8.count<=128,
              !romFilename.contains("/"),!romFilename.contains("\0"),!romFilename.hasPrefix("."),
              ["smc","sfc"].contains((romFilename as NSString).pathExtension.lowercased()) else {throw SNESOneGameMenu.failure()}
    }
}

/// Immutable source-backed review. No selector update or firmware operation is encoded here.
struct SNESOneGameMaterial:Sendable {
    let paths:SNESOneGamePaths,accepted:SNESFirmwareAcceptedInstall,originals:SNESOriginalGamesPackage
    let menu:SNESOneGameMenu,bundle:Data
    private let sourceSeal:SNESFirmwareSourceSeal,guardValue:SNESFirmwareGuard
    struct Plan:Codable {
        let schemaVersion:Int,scope:String,selectorWillChange:Bool,firmwareWriteRequested:Bool
        let id:UUID,paths:SNESOneGamePaths,binding:SNESRuntimeBinding,catalogManifestSHA256:String
        let code:String,title:String,gameCount:Int,consoleRoot:String,menuTreeSHA256:String,bundleSHA256:String,bundleBytes:Int,requiredFreeBytes:Int
        let sourceROMSHA256:String,sourceArtworkSHA256:String,sourceMetadataSHA256:String
    }
    var requiredFreeBytes:Int {menu.requiredFreeBytes}
    let reviewSHA256:String
    private let encodedPlan:Data
    private init(paths:SNESOneGamePaths,accepted:SNESFirmwareAcceptedInstall,originals:SNESOriginalGamesPackage,menu:SNESOneGameMenu,bundle:Data,seal:SNESFirmwareSourceSeal,guardValue:SNESFirmwareGuard) throws {
        self.paths=paths;self.accepted=accepted;self.originals=originals;self.menu=menu;self.bundle=bundle;sourceSeal=seal;self.guardValue=guardValue
        let p=Plan(schemaVersion:1,scope:"snes-one-game-inactive-copy",selectorWillChange:false,firmwareWriteRequested:false,
            id:menu.id,paths:paths,binding:accepted.material.trial.candidate.material.binding,catalogManifestSHA256:originals.manifestSHA256,
            code:menu.code,title:menu.title,gameCount:menu.gameCount,consoleRoot:menu.consoleRoot,menuTreeSHA256:menu.treeSHA256,
            bundleSHA256:BackupManifest.digest(bundle),bundleBytes:bundle.count,requiredFreeBytes:menu.requiredFreeBytes,
            sourceROMSHA256:menu.sourceROMSHA256,sourceArtworkSHA256:menu.sourceArtworkSHA256,sourceMetadataSHA256:menu.sourceMetadataSHA256)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        encodedPlan=try encoder.encode(p);reviewSHA256=BackupManifest.digest(encodedPlan)
    }
    static func prepare(paths:SNESOneGamePaths,accepted:SNESFirmwareAcceptedInstall,id:UUID=UUID()) throws -> Self {
        try paths.validate();let m=accepted.material,guardValue=try SNESFirmwareGuard.prepare(m)
        let operation=URL(fileURLWithPath:paths.firmwareOperation).standardizedFileURL
        guard operation.lastPathComponent=="SNESFirmware-"+m.id.uuidString,paths.firmwareReviewSHA256==accepted.reviewSHA256,
              accepted.reviewSHA256==guardValue.reviewSHA256 else {throw SNESOneGameMenu.failure()}
        let originals=try SNESOriginalGamesPackage.load(directory:URL(fileURLWithPath:paths.catalogDirectory),accepted:accepted)
        let game=try RestoreDirectory(URL(fileURLWithPath:paths.gameDirectory)),code=game.url.lastPathComponent
        let seal=try SNESFirmwareSourceSeal.capture(directories:[game.url],files:[])
        let metadata=try game.read(code+".desktop",maximum:16384),rom=try game.read(paths.romFilename,maximum:4*1024*1024+512),art=try game.read(code+".png",maximum:8*1024*1024)
        let menu=try SNESOneGameMenu.prepare(originals:originals.frame,code:code,metadata:metadata,rom:rom,artwork:art,id:id)
        let bundle=try encodeBundle(menu)
        let value=try Self(paths:paths,accepted:accepted,originals:originals,menu:menu,bundle:bundle,seal:seal,guardValue:guardValue)
        try value.validate();return value
    }
    static func encodeBundle(_ menu:SNESOneGameMenu)throws->Data {
        var files=menu.files;files["menu.manifest"]=menu.manifest
        var bundle=Data(("SWIFTHAKCHI_SNES_MENU_FILES_V1 "+menu.id.uuidString+"\n").utf8)
        for name in files.keys.sorted() {
            let bytes=files[name]!
            bundle.append(Data("FILE \(name) \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8));bundle.append(bytes);bundle.append(10)
        }
        bundle.append(Data("END \(files.count)\n".utf8))
        guard bundle.count<=9*1024*1024 else {throw SNESOneGameMenu.failure()}
        return bundle
    }
    func validate()throws {try Task.checkCancellation();try guardValue.require(accepted.material);try originals.revalidate();try sourceSeal.validate()}
    func planData()throws->Data {encodedPlan}
    static func load(directory:URL,accepted:SNESFirmwareAcceptedInstall)throws->Self {
        let d=try RestoreDirectory(directory),prefix="SNES-One-Game-"
        guard d.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(d.url.lastPathComponent.dropFirst(prefix.count))) != nil,
              Set(try d.names())==Set(["manifest.json","menu.bundle"]) else {throw SNESOneGameMenu.failure()}
        let raw=try d.read("manifest.json",maximum:65536),plan=try JSONDecoder().decode(Plan.self,from:raw)
        let value=try prepare(paths:plan.paths,accepted:accepted,id:plan.id)
        guard try value.planData()==raw,try d.read("menu.bundle",maximum:9*1024*1024)==value.bundle else {throw SNESOneGameMenu.failure()}
        try d.check();return value
    }
}
