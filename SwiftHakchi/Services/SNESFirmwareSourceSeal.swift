import Foundation
import Darwin

/// Byte validation precedes/follows capture; immutable firmware buffers are separate.
/// This detects source replacement/edits at each await without re-reading300MiB.
struct SNESFirmwareSourceSeal:Sendable {
    private struct Signature:Equatable,Sendable {
        let inode:UInt64,device:Int32,mode:UInt16,links:UInt64,uid:UInt32,gid:UInt32,size:Int64
        let mtime:Int64,mtimeNanos:Int64,ctime:Int64,ctimeNanos:Int64,flags:UInt32
        init(_ s:stat) {
            inode=UInt64(s.st_ino);device=Int32(s.st_dev);mode=UInt16(s.st_mode);links=UInt64(s.st_nlink);uid=UInt32(s.st_uid);gid=UInt32(s.st_gid);size=Int64(s.st_size)
            mtime=Int64(s.st_mtimespec.tv_sec);mtimeNanos=Int64(s.st_mtimespec.tv_nsec);ctime=Int64(s.st_ctimespec.tv_sec);ctimeNanos=Int64(s.st_ctimespec.tv_nsec);flags=UInt32(s.st_flags)
        }
        func sameParent(_ other:Self)->Bool {inode==other.inode && device==other.device && mode==other.mode && uid==other.uid && gid==other.gid}
    }
    private struct Directory:Sendable {let url:URL,signature:Signature,entries:[String:Signature]}
    private struct File:Sendable {let url:URL,parent:Signature,signature:Signature}
    private let directories:[Directory],files:[File]
    private static func directoryInfo(_ d:RestoreDirectory)throws->Signature {
        var s=stat();guard fstat(d.fd,&s)==0 else {throw RestoreDirectory.failure()};return Signature(s)
    }
    private static func fileInfo(_ name:String,in d:RestoreDirectory)throws->Signature {
        var s=stat()
        guard fstatat(d.fd,name,&s,AT_SYMLINK_NOFOLLOW)==0,s.st_mode & S_IFMT==S_IFREG,s.st_nlink==1 else {throw RestoreDirectory.failure()}
        return Signature(s)
    }
    static func capture(directories:[URL],files:[URL])throws->Self {
        try Task.checkCancellation();guard directories.count<=32,files.count<=16 else {throw RestoreDirectory.failure()}
        var seen=Set<URL>(),dirs:[Directory]=[],leaves:[File]=[]
        for url in directories where seen.insert(url.standardizedFileURL).inserted {
            let d=try RestoreDirectory(url),names=try d.names();guard names.count<=128 else {throw RestoreDirectory.failure()}
            let signature=try directoryInfo(d);var entries:[String:Signature]=[:]
            for name in names {entries[name]=try fileInfo(name,in:d)}
            try d.check();guard try directoryInfo(d)==signature else {throw RestoreDirectory.failure()}
            dirs.append(.init(url:d.url,signature:signature,entries:entries))
        }
        for url in files {
            let d=try RestoreDirectory(url.deletingLastPathComponent()),parent=try directoryInfo(d),signature=try fileInfo(url.lastPathComponent,in:d)
            try d.check();leaves.append(.init(url:d.url.appendingPathComponent(url.lastPathComponent),parent:parent,signature:signature))
        }
        let result=Self(directories:dirs,files:leaves);try result.validate();return result
    }
    func validate()throws {
        try Task.checkCancellation()
        for saved in directories {
            let d=try RestoreDirectory(saved.url)
            guard try Self.directoryInfo(d)==saved.signature,Set(try d.names())==Set(saved.entries.keys) else {throw RestoreDirectory.failure()}
            for (name,signature) in saved.entries {guard try Self.fileInfo(name,in:d)==signature else {throw RestoreDirectory.failure()}}
            try d.check();guard try Self.directoryInfo(d)==saved.signature else {throw RestoreDirectory.failure()}
        }
        for saved in files {
            let d=try RestoreDirectory(saved.url.deletingLastPathComponent())
            guard try Self.directoryInfo(d).sameParent(saved.parent),try Self.fileInfo(saved.url.lastPathComponent,in:d)==saved.signature else {throw RestoreDirectory.failure()}
            try d.check()
        }
    }
}
