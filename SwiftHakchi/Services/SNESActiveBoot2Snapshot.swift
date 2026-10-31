import Foundation
import SwiftHakchiCore

struct SNESPhysicalGeometry:Sendable,Equatable {
    let raw:Data
    let pageSize:UInt32,pagesPerBlock:UInt32,blockCount:UInt32
    init(_ raw:Data)throws {
        guard raw.count==24,raw.prefix(8)==Data("hakchi\0\0".utf8) else {throw SNESRuntimeBinding.failure()}
        func word(_ n:Int)->UInt32 {(0..<4).reduce(0) {$0 | UInt32(raw[n+$1]) << ($1*8)}}
        let page=word(12),per=word(16),blocks=word(20)
        func power(_ n:UInt32)->Bool {n>0 && n & (n-1)==0}
        guard word(8)==24,power(page),power(per),(512...16384).contains(page),
              UInt64(page)*UInt64(per)==131072,UInt64(blocks)*131072>=0xd00000 else {throw SNESRuntimeBinding.failure()}
        self.raw=raw;pageSize=page;pagesPerBlock=per;blockCount=blocks
    }
}
struct SNESPhysicalFrame:Sendable {
    enum Kind:Sendable {case geometry,active
        var count:Int {self == .geometry ? 24:7340032}
        var label:String {self == .geometry ? "SWIFTHAKCHI_SNES_PHYSICAL_GEOMETRY_V1":"SWIFTHAKCHI_SNES_PHYSICAL_ACTIVE_V1"}
    }
    let bytes:Data
    init(_ frame:Data,kind:Kind,challenge:UUID)throws {
        guard frame.count<=kind.count+512,let end=frame.prefix(256).firstIndex(of:10),
              let header=String(data:frame[..<end],encoding:.ascii) else {throw SNESRuntimeBinding.failure()}
        let fields=header.components(separatedBy:" ")
        guard fields.count==4,fields[0]==kind.label,fields[1]==challenge.uuidString,fields[2]==String(kind.count),
              SNESDataSnapshotChunk.isDigest(fields[3]) else {throw SNESRuntimeBinding.failure()}
        let tail=Data("\nSWIFTHAKCHI_SNES_PHYSICAL_END_V1 \(challenge.uuidString) \(fields[3])\n".utf8),start=end+1
        guard frame.count==start+kind.count+tail.count,frame.suffix(tail.count)==tail else {throw SNESRuntimeBinding.failure()}
        let bytes=Data(frame[start..<start+kind.count])
        guard BackupManifest.digest(bytes)==fields[3] else {throw SNESRuntimeBinding.failure()}
        self.bytes=bytes
    }
}
struct SNESBoundedReadHelper:Sendable {
    let bytes:Data,location:URL
    static let sha256="59dc6f084106cb4d08b56d9bbb6abcd9a1f9f09de3c668018432eabdb9066ae0"
    private init(bytes:Data,location:URL){self.bytes=bytes;self.location=location}
    static func load(_ url:URL)throws->Self {
        let directory=try RestoreDirectory(url.deletingLastPathComponent())
        let bytes=try directory.read(url.lastPathComponent,maximum:16384)
        guard bytes.count==11928,BackupManifest.digest(bytes)==sha256,bytes.prefix(7)==Data([0x7f,69,76,70,1,1,1]) else {throw SNESRuntimeBinding.failure()}
        func u16(_ n:Int)->Int {Int(bytes[n]) | Int(bytes[n+1]) << 8}
        func u32(_ n:Int)->UInt32 {(0..<4).reduce(0) {$0 | UInt32(bytes[n+$1]) << ($1*8)}}
        guard u16(16)==2,u16(18)==40,u16(42)==32,(1...16).contains(u16(44)) else {throw SNESRuntimeBinding.failure()}
        let offset=Int(u32(28)),count=u16(44),entry=UInt64(u32(24))
        guard offset<=bytes.count,count*32<=bytes.count-offset else {throw SNESRuntimeBinding.failure()}
        var executableEntry=false
        for i in 0..<count {
            let at=offset+i*32,type=u32(at),file=UInt64(u32(at+4)),address=UInt64(u32(at+8)),fileBytes=UInt64(u32(at+16)),memoryBytes=UInt64(u32(at+20)),flags=u32(at+24)
            guard type != 3,flags & 3 != 3 else {throw SNESRuntimeBinding.failure()}
            if type==1 {
                guard file<=UInt64(bytes.count),fileBytes<=UInt64(bytes.count)-file,fileBytes<=memoryBytes else {throw SNESRuntimeBinding.failure()}
                if flags & 1 != 0,entry>=address,entry-address<fileBytes {executableEntry=true}
            }
        }
        guard executableEntry else {throw SNESRuntimeBinding.failure()}
        try directory.check();return .init(bytes:bytes,location:directory.url.appendingPathComponent(url.lastPathComponent))
    }
    func revalidate()throws {
        guard try Self.load(location).bytes==bytes else {throw SNESRuntimeBinding.failure()}
    }
}
