import Foundation

struct GameGenieHTTPResponse:Sendable {let data:Data,status:Int,url:URL,retryAfter:String?}
struct GameGenieCatalogProgress:Sendable {let completed:Int,total:Int,game:String}
struct GameGenieCatalogDownload:Sendable {
    typealias Fetch=@Sendable(URL) async throws->GameGenieHTTPResponse
    let fetch:Fetch
    let wait:@Sendable(Duration) async throws->Void
    init(fetch:@escaping Fetch={try await GameGenieCatalogHTTP.fetch($0)},wait:@escaping @Sendable(Duration) async throws->Void={try await Task.sleep(for:$0)}) {self.fetch=fetch;self.wait=wait}
    struct Cached:Codable {let url:String,sha256:String,filename:String}
    static func robotsAllows(_ text:String,url:URL)->Bool {
        var groups:[([String],[(String,String)])]=[],agents:[String]=[],rules:[(String,String)]=[]
        func flush(){if !agents.isEmpty {groups.append((agents,rules))};agents=[];rules=[]}
        for raw in text.components(separatedBy:.newlines) {
            let line=raw.components(separatedBy:"#")[0].trimmingCharacters(in:.whitespaces)
            if line.isEmpty {flush();continue}
            let pair=line.split(separator:":",maxSplits:1).map{String($0).trimmingCharacters(in:.whitespaces)}
            guard pair.count==2 else{continue}
            let kind=pair[0].lowercased(),value=pair[1]
            if kind=="user-agent" {if !rules.isEmpty {flush()};agents.append(value.lowercased())}
            else if ["allow","disallow"].contains(kind),!value.isEmpty {rules.append((kind,value))}
        }
        flush()
        let own=groups.filter{$0.0.contains(where:{$0 != "*" && "swifthakchibetacatalog".hasPrefix($0)})}
        let applicable=own.isEmpty ? groups.filter{$0.0.contains("*")}:own
        var best = -1,allowed=true
        for (_,rules) in applicable {for (kind,path) in rules {
            let pattern="^"+NSRegularExpression.escapedPattern(for:path).replacingOccurrences(of:"\\*",with:".*").replacingOccurrences(of:"\\$",with:"$")
            if url.path.range(of:pattern,options:.regularExpression) != nil,path.count>best || (path.count==best && kind=="allow") {best=path.count;allowed=kind=="allow"}
        }}
        return allowed
    }
    func run(system:GameGenieSystem,cache:URL,progress:@escaping @Sendable(GameGenieCatalogProgress) async->Void) async throws->GameGenieOfflineCatalog {
        try Task.checkCancellation()
        let values=try cache.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory==true,values.isSymbolicLink != true else {throw GameGenieError.unsafeDestination}
        let robotsURL=URL(string:"https://gamegenie.com/robots.txt")!,termsURL=URL(string:"https://www.danworld.com/terms.html")!
        var pace=Duration.milliseconds(500)
        func request(_ url:URL) async throws->GameGenieHTTPResponse {
            try Task.checkCancellation();try await wait(pace);try Task.checkCancellation()
            let response=try await fetch(url);try Task.checkCancellation()
            guard response.url==url,response.data.count<=GameGenieHTMLImport.maximumPageBytes else {throw GameGenieCatalog.CatalogError.invalid}
            return response
        }
        let robots=try await request(robotsURL)
        guard [200,404].contains(robots.status) else {throw DownloadError.source("The site's download rules could not be checked. Try again later.")}
        let rules=robots.status==404 ? "":try GameGenieHTMLImport.html(robots.data)
        guard Self.robotsAllows(rules,url:system.indexURL) else {throw DownloadError.source("The site does not allow this catalog download.")}
        if let match=try GameGenieHTMLImport.matches("(?m)^crawl-delay:[ \\t]*([0-9]+(?:\\.[0-9]+)?)",rules).first,
           let seconds=Double(GameGenieHTMLImport.group(match,1,rules)) {
            guard seconds<=60 else {throw DownloadError.source("The site requests a longer download interval. Try a saved catalog instead.")};pace = .seconds(max(0.5,seconds))
        }
        let terms=try await request(termsURL)
        guard terms.status==200 else {throw DownloadError.source("Source notices could not be saved. Try again later.")}
        try GameGenieCatalogLibrary.write(terms.data,to:cache.appendingPathComponent("source-terms.html"))
        try GameGenieCatalogLibrary.write(robots.data,to:cache.appendingPathComponent("robots.txt"))
        let index=try await request(system.indexURL)
        guard index.status==200 else {throw DownloadError.source("The game list could not be downloaded. Try again later.")}
        let pages=try GameGenieHTMLImport.index(index.data,system:system)
        try GameGenieCatalogLibrary.write(index.data,to:cache.appendingPathComponent("index.html"))
        let manifestURL=cache.appendingPathComponent("download-manifest.json")
        var records:[Cached]=[]
        if FileManager.default.fileExists(atPath:manifestURL.path) {records=(try? JSONDecoder().decode([Cached].self,from:GameGenieCatalogLibrary.read(manifestURL))) ?? []}
        var catalog=GameGenieOfflineCatalog(system:system,effects:[],sources:[system.indexURL.absoluteString],notices:["© Danworld, Inc. — personal, noncommercial home use. Preserve source notices. Terms: "+termsURL.absoluteString])
        catalog.coverage.discovered=pages.count
        for (i,page) in pages.enumerated() {
            try Task.checkCancellation();await progress(.init(completed:i,total:pages.count,game:page.game));try Task.checkCancellation()
            guard GameGenieHTMLImport.allowed(page.url,system:system),Self.robotsAllows(rules,url:page.url) else {catalog.coverage.failedURLs.append(page.url.absoluteString);continue}
            let name=GameGenieOfflineCatalog.digest(Data(page.url.absoluteString.utf8))+".html",file=cache.appendingPathComponent(name)
            do {
                let bytes:Data
                if let record=records.first(where:{$0.url==page.url.absoluteString && $0.filename==name}),let saved=try? GameGenieCatalogLibrary.read(file,maximum:GameGenieHTMLImport.maximumPageBytes),GameGenieOfflineCatalog.digest(saved)==record.sha256 {bytes=saved}
                else {
                    let response=try await request(page.url)
                    if response.status==429 || (response.status==503 && response.retryAfter != nil) {throw DownloadError.source("The site has paused downloads. \(response.retryAfter.map{"Try again after "+$0+". "} ?? "")Download again later to resume saved progress.")}
                    guard response.status==200 else {throw GameGenieCatalog.CatalogError.invalid}
                    bytes=response.data;try GameGenieCatalogLibrary.write(bytes,to:file)
                    records.removeAll{$0.url==page.url.absoluteString};records.append(.init(url:page.url.absoluteString,sha256:GameGenieOfflineCatalog.digest(bytes),filename:name))
                    try GameGenieCatalogLibrary.write(JSONEncoder().encode(records),to:manifestURL)
                }
                let rows=try GameGenieHTMLImport.page(bytes,link:page,system:system)
                catalog=try catalog.merged(with:.init(system:system,effects:rows))
                catalog.coverage.fetched += 1
            } catch is CancellationError {throw CancellationError()}
            catch let error as DownloadError {throw error}
            catch {catalog.coverage.failedURLs.append(page.url.absoluteString)}
        }
        catalog.coverage.reviewEntries=catalog.effects.filter{!$0.reviewReasons.isEmpty}.count
        try Task.checkCancellation();await progress(.init(completed:pages.count,total:pages.count,game:"Ready to review"));return try catalog.validated()
    }
    enum DownloadError:LocalizedError {case source(String);var errorDescription:String? {if case .source(let message)=self{return message};return nil}}
}
private final class GameGenieNoRedirect: NSObject,URLSessionTaskDelegate,Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {completionHandler(nil)}
}
enum GameGenieCatalogHTTP {
    static func fetch(_ url:URL) async throws->GameGenieHTTPResponse {
        let allowed=GameGenieSystem.allCases.contains{GameGenieHTMLImport.allowed(url,system:$0)} || url.absoluteString=="https://gamegenie.com/robots.txt" || url.absoluteString=="https://www.danworld.com/terms.html"
        guard allowed else {throw GameGenieCatalog.CatalogError.invalid}
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=45;config.httpMaximumConnectionsPerHost=1;config.urlCache=nil
        let session=URLSession(configuration:config,delegate:GameGenieNoRedirect(),delegateQueue:nil);defer{session.invalidateAndCancel()}
        var request=URLRequest(url:url);request.setValue("SwiftHakchiBetaCatalog/1.0 (personal offline catalog)",forHTTPHeaderField:"User-Agent")
        let (stream,response)=try await session.bytes(for:request)
        guard let http=response as? HTTPURLResponse,http.expectedContentLength<=GameGenieHTMLImport.maximumPageBytes else {throw GameGenieCatalog.CatalogError.invalid}
        var data=Data()
        for try await byte in stream {try Task.checkCancellation();guard data.count<GameGenieHTMLImport.maximumPageBytes else {throw GameGenieCatalog.CatalogError.invalid};data.append(byte)}
        return .init(data:data,status:http.statusCode,url:response.url ?? url,retryAfter:http.value(forHTTPHeaderField:"Retry-After"))
    }
}
