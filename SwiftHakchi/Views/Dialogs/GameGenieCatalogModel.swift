import Foundation

@MainActor final class GameGenieCatalogModel:ObservableObject {
    @Published private(set) var system:GameGenieSystem
    @Published var query:String
    @Published private(set) var catalog:GameGenieOfflineCatalog?
    @Published private(set) var pending:GameGenieOfflineCatalog?
    @Published private(set) var isDownloading=false
    @Published private(set) var progress:GameGenieCatalogProgress?
    @Published private(set) var error:String?
    @Published private(set) var notice:String?
    let library:GameGenieCatalogLibrary
    let lockedSystem:GameGenieSystem?
    private var generation=UUID()
    private var task:Task<Void,Never>?
    init(workspace:URL,system:GameGenieSystem,gameName:String,lockedSystem:GameGenieSystem?=nil) {
        library = .init(workspace:workspace);self.lockedSystem=lockedSystem;self.system=lockedSystem ?? system;query=gameName;reload()
    }
    var preferredGame:String? {
        let matches=catalog?.searchGames(query) ?? []
        return matches.first{catalog?.searchKey($0)==catalog?.searchKey(query)} ?? (matches.count==1 ? matches[0]:nil)
    }
    func reload(){do{catalog=try library.load(system);error=nil}catch{catalog=nil;self.error=error.localizedDescription}}
    func selectSystem(_ system:GameGenieSystem) {guard lockedSystem==nil || lockedSystem==system else{return};cancel();self.system=system;pending=nil;notice=nil;progress=nil;reload()}
    func cancel(){generation=UUID();task?.cancel();task=nil;isDownloading=false}
    func startDownload(){guard !isDownloading else{return};task=Task {await download()}}
    func download(using downloader:GameGenieCatalogDownload=GameGenieCatalogDownload()) async {
        guard !Task.isCancelled,!isDownloading else{return}
        let token=generation,selected=system;isDownloading=true;error=nil;notice=nil
        do {
            let folder=try library.folder(create:true),downloads=folder.appendingPathComponent("Downloads"),cache=downloads.appendingPathComponent(selected.rawValue)
            for path in [downloads,cache] {
                if !FileManager.default.fileExists(atPath:path.path){try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
                let v=try path.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard v.isDirectory==true,v.isSymbolicLink != true else{throw GameGenieError.unsafeDestination}
            }
            let result=try await downloader.run(system:selected,cache:cache,progress:{[weak self] value in
                await self?.updateProgress(value,token:token)
            })
            guard generation==token,system==selected,!Task.isCancelled else{return}
            try review(result)
        } catch is CancellationError {} catch {if generation==token {self.error=error.localizedDescription}}
        if generation==token {isDownloading=false;task=nil}
    }
    private func updateProgress(_ value:GameGenieCatalogProgress,token:UUID) {if token==generation {progress=value}}
    func review(_ incoming:GameGenieOfflineCatalog)throws {
        guard incoming.system==system else {throw GameGenieCatalog.CatalogError.invalid}
        let base=try library.load(system),merged=try base?.merged(with:incoming) ?? incoming.validated()
        pending=merged
        let duplicates=(base?.effects.count ?? 0)+incoming.effects.count-merged.effects.count
        let new=merged.effects.count-(base?.effects.count ?? 0)
        notice="\(new) new effects · \(duplicates) duplicate groups combined · \(merged.coverage.reviewEntries) entries to review."
    }
    func acceptReview()throws {
        guard let pending else {return};try library.install(pending);catalog=pending;self.pending=nil;notice="Codes saved on this Mac. Search and browse them offline."
    }
    func discardReview(){pending=nil;notice=nil}
    func showError(_ error:Error){self.error=error.localizedDescription}
}
