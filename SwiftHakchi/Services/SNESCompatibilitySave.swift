import Foundation
import SwiftHakchiCore

/// Inert engine-specific save data. A file cannot confer console launch authority.
/// This wrapper is never passed directly to libretro; a checked bridge must unwrap it.
struct SNESCompatibilitySave:Sendable {
    enum Kind:String,Codable,Sendable {case battery,suspend}
    static let engineID=SNESCompatibilityCorePackage.engineID
    private static let magic=Data("HAKCHI_SNES_ENGINE_SAVE_V1\n".utf8)
    private static let maximumHeaderBytes=1024
    private struct Header:Codable {
        let version:Int
        let engineID:String
        let kind:Kind
        let gameCode:String
        let romSHA256:String
        let payloadByteCount:Int
        let payloadSHA256:String
    }
    let bytes:Data
    let payload:Data
    private static func failure()->RecoveryProbeError {
        .refused("This save belongs to a different game or emulator, or could not be verified. The original save was not changed.")
    }
    private static func validIdentity(_ code:String,_ sha:String)->Bool {
        code.range(of:#"^CLV-U-[A-Z0-9]{5}$"#,options:.regularExpression) != nil &&
            sha.count==64 && SNESRuntimeBinding.hex(sha)
    }
    private static func maximum(_ kind:Kind)->Int {kind == .battery ? 128*1024:16*1024*1024}
    private static func encode(_ header:Header)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(header)
    }
    static func create(payload:Data,kind:Kind,gameCode:String,romSHA256:String)throws->Self {
        guard validIdentity(gameCode,romSHA256),(1...maximum(kind)).contains(payload.count) else {throw failure()}
        let header=try encode(Header(version:1,engineID:engineID,kind:kind,gameCode:gameCode,romSHA256:romSHA256,
            payloadByteCount:payload.count,payloadSHA256:BackupManifest.digest(payload)))
        guard header.count<=maximumHeaderBytes else {throw failure()}
        var bytes=magic;bytes.append(Data("\(header.count)\n".utf8));bytes.append(header);bytes.append(10);bytes.append(payload)
        return try Self(bytes,kind:kind,gameCode:gameCode,romSHA256:romSHA256)
    }
    /// Verifies an inert save envelope against a captured local library ROM.
    /// This does not authenticate a console session or authorize a restore.
    static func forLibraryRecovery(_ bytes:Data,kind:Kind,game:Game,source:SNESLibraryROMSource)throws->Self {
        let directory=URL(fileURLWithPath:game.romPath,isDirectory:true).standardizedFileURL
        guard game.source == .local,game.consoleType == .snesUsa,
              directory.lastPathComponent == game.code,
              directory == source.directory.standardizedFileURL else {throw failure()}
        let parent=try RestoreDirectory(directory)
        let names=try parent.names().filter { ["sfc","smc"].contains(URL(fileURLWithPath:$0).pathExtension.lowercased()) }
        guard names.count==1,names.first==source.filename else {throw failure()}
        try source.verify()
        let save=try Self(bytes,kind:kind,gameCode:game.code,romSHA256:source.sha256)
        try source.verify();try parent.check()
        // A second snapshot catches library changes during validation. Callers
        // still need exclusive access to rule out concurrent external changes.
        let finalNames=try parent.names().filter { ["sfc","smc"].contains(URL(fileURLWithPath:$0).pathExtension.lowercased()) }
        guard finalNames.count==1,finalNames.first==source.filename else {throw failure()}
        try parent.check()
        return save
    }
    init(_ bytes:Data,kind:Kind,gameCode:String,romSHA256:String)throws {
        guard Self.validIdentity(gameCode,romSHA256),bytes.count<=Self.maximum(kind)+Self.maximumHeaderBytes+128,
              bytes.starts(with:Self.magic) else {throw Self.failure()}
        let tail=bytes.dropFirst(Self.magic.count)
        guard let end=tail.prefix(5).firstIndex(of:10),let number=String(data:tail[..<end],encoding:.ascii),
              let count=Int(number),String(count)==number,(1...Self.maximumHeaderBytes).contains(count) else {throw Self.failure()}
        let rest=tail[tail.index(after:end)...]
        guard rest.count>count,rest[rest.index(rest.startIndex,offsetBy:count)]==10 else {throw Self.failure()}
        let rawHeader=Data(rest.prefix(count)),header=try JSONDecoder().decode(Header.self,from:rawHeader)
        let payload=Data(rest.dropFirst(count+1))
        guard header.version==1,header.engineID==Self.engineID,header.kind==kind,header.gameCode==gameCode,
              header.romSHA256==romSHA256,header.payloadByteCount==payload.count,(1...Self.maximum(kind)).contains(payload.count),
              header.payloadSHA256==BackupManifest.digest(payload),try Self.encode(header)==rawHeader else {throw Self.failure()}
        self.bytes=Data(bytes);self.payload=payload
    }
}
