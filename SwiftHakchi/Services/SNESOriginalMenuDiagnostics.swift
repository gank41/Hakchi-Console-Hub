import Foundation
import SwiftHakchiCore

/// Bounded text snapshots. Empty program logs are valid; absent files or failed producers are not.
struct SNESOriginalMenuDiagnostics {
    let raw:Data
    init(_ raw:Data,nonce:String) throws {
        guard raw.count<=65536 else {throw SNESRuntimeBinding.failure()}
        let bytes=Array(raw);var cursor=0
        func line() throws -> String {
            let endLimit=min(bytes.count,cursor+1024)
            guard cursor<endLimit,let end=bytes[cursor..<endLimit].firstIndex(of:10),
                  bytes[cursor..<end].allSatisfy({(32...126).contains($0)}) else {throw SNESRuntimeBinding.failure()}
            let text=String(decoding:bytes[cursor..<end],as:UTF8.self);cursor=end+1;return text
        }
        guard try line()=="SWIFTHAKCHI_ORIGINAL_LOGS_V1",try line()=="NONCE="+nonce else {throw SNESRuntimeBinding.failure()}
        func record(_ name:String,required:Bool) throws {
            let header=try line().components(separatedBy:" ")
            guard header.count==4,header[0]=="LOG",header[1]==name,let size=Int(header[2]),String(size)==header[2],
                  (0...8192).contains(size),!required || size>0,size<bytes.count-cursor else {throw SNESRuntimeBinding.failure()}
            let data=Data(bytes[cursor..<cursor+size]);cursor+=size
            guard BackupManifest.digest(data)==header[3],bytes[cursor]==10 else {throw SNESRuntimeBinding.failure()};cursor+=1
        }
        for name in ["startup-stages","init.log","daemon.log","udev.log","menu.log","kernel"] {try record(name,required:name=="startup-stages" || name=="kernel")}
        if bytes[cursor...].starts(with:Array("LOG transport-stderr ".utf8)) {try record("transport-stderr",required:false)}
        guard try line()=="END",cursor==bytes.count else {throw SNESRuntimeBinding.failure()}
        self.raw=raw
    }
    static func appendingStderr(_ stderr:Data,to raw:Data,nonce:String) throws -> Data {
        _=try Self(raw,nonce:nonce)
        let bounded=Data(stderr.prefix(8192))
        let result=raw.dropLast(4)+Data("LOG transport-stderr \(bounded.count) \(BackupManifest.digest(bounded))\n".utf8)+bounded+Data("\nEND\n".utf8)
        _=try Self(Data(result),nonce:nonce);return Data(result)
    }
}
