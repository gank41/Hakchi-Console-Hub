import Foundation
import ImageIO
import SwiftHakchiCore

/// Parses read-only console observations; these do not authenticate a session
/// or authorize a restore, transfer, or deletion.
struct SNESCompatibilityManagerInventory {
    struct Observation:Sendable {
        let sessions:[SNESRecoveryBinding.ObservedManagerScreenshotSession]
        let incompleteWorkspaces:[String]
    }
    static func prepare(game:Game,source:SNESLibraryROMSource,helperSHA256:String) throws -> String {
        guard SNESDataSnapshotChunk.isDigest(helperSHA256) else {throw SNESLibraryMenu.failure()}
        _ = try SNESCompatibilityLaunchRequest.prepare(game:game,source:source,session:Data([1]+Array(repeating:0,count:15)),epoch:1)
        let command="B=/mnt/swifthakchi/busybox; P=/mnt/swifthakchi/snes-compat/preflight; [ -f \"$P\" ] && [ ! -L \"$P\" ] || exit 1; h=$(\"$B\" sha256sum \"$P\") || exit 1; [ \"${h%% *}\" = '"+helperSHA256+"' ] || exit 1; \"$P\" --observe-manager-inventory '"+game.code+"' '"+source.sha256+"'"
        guard command.utf8.count<1020 else {throw SNESLibraryMenu.failure()}
        return command
    }
    static func parse(_ data:Data,game:Game,source:SNESLibraryROMSource) throws -> Observation {
        guard (10...(10+16*(2+2165))).contains(data.count) else {throw SNESLibraryMenu.failure()}
        _ = try SNESCompatibilityLaunchRequest.prepare(game:game,source:source,session:Data([1]+Array(repeating:0,count:15)),epoch:1)
        let bytes=[UInt8](data)
        guard bytes.starts(with:Array("HCMINV2\0".utf8)) else {throw SNESLibraryMenu.failure()}
        let count=Int(bytes[8])|(Int(bytes[9])<<8)
        guard count<=16 else {throw SNESLibraryMenu.failure()}
        var offset=10,result:[SNESRecoveryBinding.ObservedManagerScreenshotSession]=[],incomplete:[String]=[],sessions=Set<String>()
        for _ in 0..<count {
            guard offset+2<=bytes.count else {throw SNESLibraryMenu.failure()}
            let length=Int(bytes[offset])|(Int(bytes[offset+1])<<8);offset+=2
            guard length<=bytes.count-offset else {throw SNESLibraryMenu.failure()}
            if length==43 {
                let token=bytes[offset..<(offset+length)]
                guard token.prefix(11).elementsEqual("checkpoint-".utf8),token.dropFirst(11).allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
                      token.dropFirst(11).contains(where:{$0 != 48}),let workspace=String(bytes:token,encoding:.ascii),
                      sessions.insert(String(workspace.dropFirst(11))).inserted else {throw SNESLibraryMenu.failure()}
                incomplete.append(workspace);offset+=length;continue
            }
            guard (119...2165).contains(length) else {throw SNESLibraryMenu.failure()}
            let item=try SNESRecoveryBinding.observeConsoleManagerScreenshotRecord(Data(bytes[offset..<(offset+length)]),game:game,source:source)
            let session=item.request.frame[83..<99].map{String(format:"%02x",$0)}.joined()
            guard sessions.insert(session).inserted else {throw SNESLibraryMenu.failure()}
            result.append(item);offset+=length
        }
        guard offset==bytes.count else {throw SNESLibraryMenu.failure()}
        try source.verify()
        return .init(sessions:result,incompleteWorkspaces:incomplete)
    }
}

/// Read-only comparison against independently trusted launch expectations.
/// Descriptor contents and hashes cannot authenticate the caller or a console.
/// This does not establish stopped writers or authorize restore or deletion.
struct SNESRecoveryBinding {
    struct Region: Equatable {
        let path:String
        let type:UInt32
        let device:UInt64
        let inode:UInt64
    }
    private struct PhysicalRegion:Hashable {
        let device:UInt64
        let inode:UInt64
        let foldedName:[UInt8]
    }
    static func validGameCode(_ code:String)->Bool {
        let bytes=Array(code.utf8.prefix(12))
        return bytes.count == 11 && bytes.prefix(6).elementsEqual("CLV-U-".utf8) && bytes.dropFirst(6).allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
        }
    }
    static func boundedPathBytes(_ path:String)->[UInt8]? {
        let bytes=Array(path.utf8.prefix(1024))
        return bytes.count < 1024 ? bytes : nil
    }
    private static func failure()->RecoveryProbeError {
        .refused("The compatibility session could not be verified. The original save was not changed.")
    }
    private static func completePNGChunks(_ image:Data)->Bool {
        let bytes=[UInt8](image);var offset=8, first=true, hasImageData=false, chunks=0
        func number(_ p:Int)->UInt32 {
            (UInt32(bytes[p])<<24)|(UInt32(bytes[p+1])<<16)|(UInt32(bytes[p+2])<<8)|UInt32(bytes[p+3])
        }
        while offset<=bytes.count-12 {
            chunks += 1;guard chunks<=1024 else {return false}
            let count=Int(number(offset))
            guard count<=bytes.count-offset-12 else {return false}
            let type=Array(bytes[(offset+4)..<(offset+8)])
            if first && (type != [73,72,68,82] || count != 13) {return false}
            first=false
            let end=offset+8+count
            guard CRC32.checksum(Data(bytes[(offset+4)..<end]))==number(end) else {return false}
            if type == [73,68,65,84] {hasImageData=true}
            offset=end+4
            if type == [73,69,78,68] {return count==0 && hasImageData && offset==bytes.count}
        }
        return false
    }
    private static func managerPath(_ path:String,game:String)->Bool {
        let bytes=Array(path.utf8)
        let prefixes=["/var/lib/clover/profiles/0/\(game)/", "/var/cache/clover/volatile/\(game)/"]
        guard !bytes.isEmpty,bytes.count<1024,prefixes.contains(where:path.hasPrefix),
              URL(fileURLWithPath:path).standardizedFileURL.path==path,
              bytes.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==45||$0==46||$0==95||$0==47}) else {return false}
        return !path.hasSuffix("/")
    }
    struct ManagerScreenshotPaths:Equatable,Sendable {
        let savePath:String?, imagePath:String?
    }
    struct ObservedManagerScreenshotSession:Sendable {
        let request:SNESCompatibilityLaunchRequest, paths:ManagerScreenshotPaths
    }
    /// Correlates a discovered record to a local game and ROM. The session
    /// and paths remain untrusted observations; this never authorizes writes.
    static func observeConsoleManagerScreenshotRecord(_ raw:Data,game:Game,source:SNESLibraryROMSource) throws -> ObservedManagerScreenshotSession {
        guard (119...2165).contains(raw.count) else {throw failure()}
        let bytes=[UInt8](raw)
        guard bytes.starts(with:Array("HCSHOT1\0".utf8)) else {throw failure()}
        let request=try SNESCompatibilityLaunchRequest.observeConsoleFrame(Data(bytes[8..<115]),game:game,source:source)
        let paths=try observeManagerScreenshotRecord(raw,request:request)
        return .init(request:request,paths:paths)
    }
    /// Reads bounded correlation data for an independently selected request.
    /// These paths are untrusted observations and do not authorize recovery.
    static func observeManagerScreenshotRecord(_ raw:Data,request:SNESCompatibilityLaunchRequest) throws -> ManagerScreenshotPaths {
        let prepared=try SNESCompatibilityPreflightCommand.prepare(request:request,helperSHA256:String(repeating:"0",count:64))
        let frame=prepared.input,game=String(decoding:frame[8..<19],as:UTF8.self),bytes=[UInt8](raw)
        let header=8+107+4
        guard bytes.count>=header,bytes.count<=header+2046,bytes.starts(with:Array("HCSHOT1\0".utf8)),
              Data(bytes[8..<115])==frame else {throw failure()}
        let saveCount=Int(bytes[115])|(Int(bytes[116])<<8),imageCount=Int(bytes[117])|(Int(bytes[118])<<8)
        guard saveCount<1024,imageCount<1024,(saveCount>0 || imageCount>0),header+saveCount+imageCount==bytes.count,
              let save=String(bytes:bytes[header..<(header+saveCount)],encoding:.ascii),
              let image=String(bytes:bytes[(header+saveCount)...],encoding:.ascii),
              (image.isEmpty || managerPath(image,game:game)),
              (save.isEmpty || (managerPath(save,game:game) && (image.isEmpty || save.lowercased() != image.lowercased()))) else {throw failure()}
        try request.verifySource()
        return ManagerScreenshotPaths(savePath:save.isEmpty ? nil:save,imagePath:image.isEmpty ? nil:image)
    }
    /// Compares a console manager record to paths reviewed independently by
    /// the caller. This does not authenticate the console or authorize writes.
    static func validateManagerScreenshotRecord(_ raw:Data,request:SNESCompatibilityLaunchRequest,
                                                expectedSavePath:String?,expectedImagePath:String) throws -> Bool {
        let observed=try observeManagerScreenshotRecord(raw,request:request)
        guard observed.savePath==expectedSavePath,observed.imagePath==expectedImagePath else {throw failure()}
        return true
    }
    private static func validateDescriptor(_ descriptor:Data,gameCode:String,romSHA256:String,
                                           session:Data,epoch:UInt64,regions:[Region]) throws {
        guard descriptor.count < 20_000,session.count == 16,session.contains(where:{$0 != 0}),
              epoch > 0,(1...16).contains(regions.count),validGameCode(gameCode),
              SNESDataSnapshotChunk.isDigest(romSHA256) else {throw failure()}
        let hex=session.map{String(format:"%02x",$0)}.joined()
        var expected="HC-BINDING-1\n\(gameCode)\n\(romSHA256)\n\(hex)\n\(epoch)\n\(regions.count)\n"
        var paths=Set<String>()
        var physicalRegions=Set<PhysicalRegion>()
        for region in regions {
            let path=region.path
            guard let bytes=boundedPathBytes(path),bytes.first==47,!bytes.contains(0),!bytes.contains(10),!bytes.contains(13),
                  paths.insert(path).inserted,let slash=path.lastIndex(of:"/") else {throw failure()}
            let name=path[path.index(after:slash)...], nameBytes=name.utf8
            guard !name.isEmpty,nameBytes.count<64,name != ".",name != "..",nameBytes.allSatisfy({
                (48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==45||$0==46||$0==95
            }) else {throw failure()}
            let foldedName=nameBytes.map { (65...90).contains($0) ? $0+32 : $0 }
            guard !foldedName.starts(with:"intent".utf8),!foldedName.starts(with:"checkpoint-".utf8) else {throw failure()}
            guard physicalRegions.insert(PhysicalRegion(device:region.device,inode:region.inode,foldedName:foldedName)).inserted else {throw failure()}
            expected += "\(region.type) \(region.device) \(region.inode) \(path)\n"
        }
        guard let canonical=expected.data(using:.utf8),canonical.count<20_000,descriptor==canonical else {throw failure()}
    }
    /// Validates a read-only screenshot candidate against independently reviewed
    /// session metadata. Neither the digest nor the binding authenticates a
    /// console or proves the screenshot completed before an interruption.
    static func validateStagedScreenshot(descriptor:Data,request:SNESCompatibilityLaunchRequest,
                                         regions:[Region],expectedImagePath:String,image:Data,
                                         expectedSHA256:String) throws -> Data {
        let preflight=try SNESCompatibilityPreflightCommand.prepare(request:request,helperSHA256:String(repeating:"0",count:64))
        let frame=preflight.input,game=String(decoding:frame[8..<19],as:UTF8.self)
        let token=Data(frame[83..<99])
        let epoch=(0..<8).reduce(UInt64(0)) { $0 | UInt64(frame[99+$1]) << (8*$1) }
        let imageRegions=regions.filter{($0.type==100 || $0.type==103) && $0.path==expectedImagePath}
        let prefixes=["/var/lib/clover/profiles/0/\(game)/", "/var/cache/clover/volatile/\(game)/"]
        guard imageRegions.count==1,imageRegions[0].path==expectedImagePath,
              prefixes.contains(where:expectedImagePath.hasPrefix),expectedImagePath.hasSuffix(".png"),
              URL(fileURLWithPath:expectedImagePath).standardizedFileURL.path==expectedImagePath,
              (57...8*1024*1024).contains(image.count),SNESDataSnapshotChunk.isDigest(expectedSHA256),
              BackupManifest.digest(image)==expectedSHA256,
              image.starts(with:[137,80,78,71,13,10,26,10]),
              image.dropFirst(8).starts(with:[0,0,0,13,73,72,68,82]),
              image.suffix(12).elementsEqual([0,0,0,0,73,69,78,68,174,66,96,130]),
              completePNGChunks(image),
              image[image.startIndex+24]==8,[2,6].contains(image[image.startIndex+25]),
              image[image.startIndex+26]==0,image[image.startIndex+27]==0,image[image.startIndex+28]==0,
              let source=CGImageSourceCreateWithData(image as CFData,nil),CGImageSourceGetCount(source)==1,
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,
              let height=properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width),(1...4096).contains(height),(width*(image[image.startIndex+25]==6 ? 4:3)+1)*height<=16*1024*1024,
              let decoded=CGImageSourceCreateImageAtIndex(source,0,nil),decoded.width==width,decoded.height==height else {throw failure()}
        try validateDescriptor(descriptor,gameCode:game,romSHA256:request.source.sha256,session:token,epoch:epoch,regions:regions)
        try request.verifySource()
        return image
    }
    /// Correlates a retained image with an independently reviewed manager
    /// record. The caller authenticates the source and retained locations and
    /// must still obtain authorization before any console write or deletion.
    static func validateRetainedScreenshot(descriptor:Data,managerRecord:Data,request:SNESCompatibilityLaunchRequest,
                                           regions:[Region],expectedRetainedPath:String,expectedManagerSavePath:String?,
                                           expectedManagerImagePath:String,image:Data,expectedSHA256:String) throws -> Data {
        let prepared=try SNESCompatibilityPreflightCommand.prepare(request:request,helperSHA256:String(repeating:"0",count:64))
        let game=String(decoding:prepared.input[8..<19],as:UTF8.self)
        let persistentParent="/var/lib/clover/profiles/0/\(game)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        guard URL(fileURLWithPath:expectedRetainedPath).deletingLastPathComponent().path == persistentParent,
              expectedRetainedPath.lowercased() != expectedManagerImagePath.lowercased(),
              regions.filter({$0.type==100 && $0.path==expectedRetainedPath}).count==1 else {throw failure()}
        try validateManagerScreenshotRecord(managerRecord,request:request,expectedSavePath:expectedManagerSavePath,expectedImagePath:expectedManagerImagePath)
        let result=try validateStagedScreenshot(descriptor:descriptor,request:request,regions:regions,
            expectedImagePath:expectedRetainedPath,image:image,expectedSHA256:expectedSHA256)
        try request.verifySource();return result
    }
    /// Matches the experimental session-named retained image. Callers must
    /// authenticate the console, source and manager paths; this validates
    /// correlation only and never authorizes restore or cleanup.
    static func validateSessionRetainedScreenshot(descriptor:Data,managerRecord:Data,request:SNESCompatibilityLaunchRequest,
                                                  regions:[Region],expectedManagerSavePath:String?,expectedManagerImagePath:String,
                                                  image:Data,expectedSHA256:String) throws -> Data {
        let prepared=try SNESCompatibilityPreflightCommand.prepare(request:request,helperSHA256:String(repeating:"0",count:64))
        let game=String(decoding:prepared.input[8..<19],as:UTF8.self)
        let token=prepared.input[83..<99].map{String(format:"%02x",$0)}.joined()
        let path="/var/lib/clover/profiles/0/\(game)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)/shot-\(token).png"
        return try validateRetainedScreenshot(descriptor:descriptor,managerRecord:managerRecord,request:request,
            regions:regions,expectedRetainedPath:path,expectedManagerSavePath:expectedManagerSavePath,
            expectedManagerImagePath:expectedManagerImagePath,image:image,expectedSHA256:expectedSHA256)
    }
    static func validateSessionRetainedState(descriptor:Data,managerRecord:Data,request:SNESCompatibilityLaunchRequest,game:Game,
                                             regions:[Region],expectedManagerSavePath:String,expectedManagerImagePath:String?,
                                             state:Data,expectedSHA256:String) throws -> SNESCompatibilitySave {
        let prepared=try SNESCompatibilityPreflightCommand.prepare(request:request,helperSHA256:String(repeating:"0",count:64))
        let frame=prepared.input,code=String(decoding:frame[8..<19],as:UTF8.self),token=Data(frame[83..<99])
        let epoch=(0..<8).reduce(UInt64(0)) { $0 | UInt64(frame[99+$1]) << (8*$1) }
        let hex=token.map{String(format:"%02x",$0)}.joined()
        let path="/var/lib/clover/profiles/0/\(code)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)/state-\(hex).state"
        let observed=try observeManagerScreenshotRecord(managerRecord,request:request),retainedStates=regions.filter{$0.type==101}
        guard game.code==code,observed.savePath==expectedManagerSavePath,observed.imagePath==expectedManagerImagePath,
              retainedStates.count==1,retainedStates[0].path==path,
              (1...16*1024*1024).contains(state.count),SNESDataSnapshotChunk.isDigest(expectedSHA256),
              BackupManifest.digest(state)==expectedSHA256 else {throw failure()}
        try validateDescriptor(descriptor,gameCode:code,romSHA256:request.source.sha256,session:token,epoch:epoch,regions:regions)
        try request.verifySource()
        let envelope=try SNESCompatibilitySave.create(payload:state,kind:.suspend,gameCode:code,romSHA256:request.source.sha256)
        return try SNESCompatibilitySave.forLibraryRecovery(envelope.bytes,kind:.suspend,game:game,source:request.source)
    }
    static func validate(descriptor:Data,save:Data,kind:SNESCompatibilitySave.Kind,game:Game,
                         source:SNESLibraryROMSource,session:Data,epoch:UInt64,
                         regions:[Region]) throws -> SNESCompatibilitySave {
        try validateDescriptor(descriptor,gameCode:game.code,romSHA256:source.sha256,session:session,epoch:epoch,regions:regions)
        return try SNESCompatibilitySave.forLibraryRecovery(save,kind:kind,game:game,source:source)
    }
    /// Compares an already reviewed Mac snapshot with one exact console binding.
    /// The caller must authenticate the console observation, stop writers and
    /// establish exclusive access. A match does not authorize a console write.
    static func validateBackupEvidence(descriptor:Data,evidence:SNESCompatibilityBackupEvidence,
                                       request:SNESCompatibilityLaunchRequest,region:Region) throws -> SNESCompatibilityBackupEvidence.Original {
        let expectedPath="/var/lib/clover/profiles/0/\(evidence.gameCode)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(evidence.romSHA256)/battery.srm"
        guard region.type==0,region.path==expectedPath else {throw failure()}
        try evidence.validate(request:request)
        try validateDescriptor(descriptor,gameCode:evidence.gameCode,romSHA256:evidence.romSHA256,
                               session:evidence.session,epoch:evidence.epoch,regions:[region])
        try evidence.validate(request:request)
        return evidence.original
    }
    /// Compare the frontend's two-region binding; the return value covers
    /// battery SRAM only. RTC backup/recovery requires separate evidence.
    static func validateBackupEvidence(descriptor: Data, evidence: SNESCompatibilityBackupEvidence,
                                       request: SNESCompatibilityLaunchRequest, regions: [Region]) throws -> SNESCompatibilityBackupEvidence.Original {
        let base = "/var/lib/clover/profiles/0/\(evidence.gameCode)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(evidence.romSHA256)"
        guard regions.count == 2, regions[0].type == 0, regions[0].path == base + "/battery.srm",
              regions[1].type == 1, regions[1].path == base + "/battery.rtc",
              regions[0].device == regions[1].device, regions[0].inode == regions[1].inode else { throw failure() }
        try evidence.validate(request: request)
        try validateDescriptor(descriptor, gameCode: evidence.gameCode, romSHA256: evidence.romSHA256,
                               session: evidence.session, epoch: evidence.epoch, regions: regions)
        try evidence.validate(request: request)
        return evidence.original
    }

}
