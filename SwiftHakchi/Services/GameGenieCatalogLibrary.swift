import Foundation
import Darwin

struct GameGenieCatalogLibrary:Sendable {
    let workspace:URL
    var bundledCatalogDirectory:URL?=Bundle.main.resourceURL?.appendingPathComponent("GameGenieCatalogs",isDirectory:true)
    func folder(create:Bool)throws->URL {
        var path=workspace
        for part in ["","Library","Cheats","Catalogs"] {
            if !part.isEmpty {path.appendPathComponent(part,isDirectory:true)}
            if !FileManager.default.fileExists(atPath:path.path) {
                // Check a dangling link even when fileExists follows it to a missing target.
                if (try? path.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true {throw GameGenieError.unsafeDestination}
                if create {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
                else {continue}
            }
            if FileManager.default.fileExists(atPath:path.path) {
                let values=try path.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values.isDirectory==true,values.isSymbolicLink != true else {throw GameGenieError.unsafeDestination}
            }
        }
        return path
    }
    static func read(_ url:URL,maximum:Int=GameGenieOfflineCatalog.maximumBytes)throws->Data {
        var st=stat();guard lstat(url.path,&st)==0,(st.st_mode & S_IFMT)==S_IFREG,st.st_nlink==1,st.st_size>=0,st.st_size<=maximum else {throw GameGenieError.unsafeDestination}
        return try Data(contentsOf:url)
    }
    static func write(_ data:Data,to url:URL)throws {
        var st=stat()
        if lstat(url.path,&st)==0 {_=try read(url,maximum:max(data.count,GameGenieOfflineCatalog.maximumBytes))}
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func bundled(_ system:GameGenieSystem)throws->GameGenieOfflineCatalog? {
        guard let root=bundledCatalogDirectory,FileManager.default.fileExists(atPath:root.path) else{return nil}
        let values=try root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory==true,values.isSymbolicLink != true else {throw GameGenieError.unsafeDestination}
        let file=root.appendingPathComponent("catalog-\(system.rawValue)-v2.json")
        guard FileManager.default.fileExists(atPath:file.path) else{return nil}
        let catalog=try GameGenieOfflineCatalog.decode(Self.read(file))
        guard catalog.system==system else {throw GameGenieCatalog.CatalogError.invalid}
        return catalog
    }
    func load(_ system:GameGenieSystem)throws->GameGenieOfflineCatalog? {
        let included=try bundled(system)
        let path=try folder(create:false).appendingPathComponent("catalog-\(system.rawValue)-v2.json")
        if FileManager.default.fileExists(atPath:path.path) {
            let value=try GameGenieOfflineCatalog.decode(Self.read(path))
            guard value.system==system else {throw GameGenieCatalog.CatalogError.invalid}
            return try included?.merged(with:value) ?? value
        }
        if system == .nes,let old=try GameGenieCatalogStore.load(workspace:workspace) {
            let value=try GameGenieOfflineCatalog.migrating(old)
            return try included?.merged(with:value) ?? value
        }
        return included
    }
    func decodeImport(_ data:Data)throws->GameGenieOfflineCatalog {
        if let old=try? GameGenieCatalog.decode(data) {return try .migrating(old)}
        return try GameGenieOfflineCatalog.decode(data)
    }
    func install(_ catalog:GameGenieOfflineCatalog)throws {
        let bytes=try catalog.encoded(),parent=try folder(create:true),file=parent.appendingPathComponent("catalog-\(catalog.system.rawValue)-v2.json")
        var st=stat()
        if lstat(file.path,&st)==0 {
            let previous=try Self.read(file)
            let history=parent.appendingPathComponent("History",isDirectory:true)
            if !FileManager.default.fileExists(atPath:history.path) {try FileManager.default.createDirectory(at:history,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
            let values=try history.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isDirectory==true,values.isSymbolicLink != true else {throw GameGenieError.unsafeDestination}
            try Self.write(previous,to:history.appendingPathComponent("\(catalog.system.rawValue)-\(UUID().uuidString).json"))
        }
        try Self.write(bytes,to:file)
    }
}
