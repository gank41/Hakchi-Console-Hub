import Foundation

struct GameGeniePageLink:Codable,Equatable,Sendable {let game:String,url:URL}
enum GameGenieHTMLImport {
    static let maximumPageBytes=2*1024*1024
    static func allowed(_ url:URL,system:GameGenieSystem)->Bool {
        guard url.scheme=="https",url.host=="gamegenie.com",url.user==nil,url.password==nil,url.port==nil,url.query==nil,url.fragment==nil,
              !url.absoluteString.contains("%"),!url.path.contains("..") else{return false}
        let prefix="/cheats/gamegenie/\(system.rawValue)/"
        return url.path.hasPrefix(prefix) && String(url.path.dropFirst(prefix.count)).range(of:"^[A-Za-z0-9_-]+\\.html$",options:.regularExpression) != nil
    }
    static func matches(_ pattern:String,_ text:String)throws->[NSTextCheckingResult] {
        try NSRegularExpression(pattern:pattern,options:[.caseInsensitive,.dotMatchesLineSeparators]).matches(in:text,range:NSRange(text.startIndex...,in:text))
    }
    static func group(_ match:NSTextCheckingResult,_ index:Int,_ text:String)->String {guard let r=Range(match.range(at:index),in:text) else{return ""};return String(text[r])}
    static func html(_ data:Data)throws->String {
        guard data.count<=maximumPageBytes,let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1),!text.contains("\0") else {throw GameGenieCatalog.CatalogError.invalid};return text
    }
    static func plain(_ html:String)->String {
        var text=html.replacingOccurrences(of:"(?is)<(script|style)\\b[^>]*>.*?</\\1>",with:"",options:.regularExpression)
        text=text.replacingOccurrences(of:"(?is)<br\\s*/?>|</(?:p|div|tr|li)>",with:"\n",options:.regularExpression).replacingOccurrences(of:"(?s)<[^>]*>",with:"",options:.regularExpression)
        for (a,b) in [("&nbsp;"," "),("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'"),("&apos;","'")] {text=text.replacingOccurrences(of:a,with:b)}
        if let rows=try? matches("&#(x[0-9a-f]+|[0-9]+);",text) {
            for row in rows.reversed() {
                let code=group(row,1,text),value=UInt32(code.hasPrefix("x") ? String(code.dropFirst()):code,radix:code.hasPrefix("x") ? 16:10)
                if let value,let scalar=UnicodeScalar(value),value != 0,let range=Range(row.range,in:text) {text.replaceSubrange(range,with:String(scalar))}
            }
        }
        return text.replacingOccurrences(of:"\r",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func index(_ data:Data,system:GameGenieSystem)throws->[GameGeniePageLink] {
        let text=try html(data);var seen=Set<URL>(),result:[GameGeniePageLink]=[]
        for row in try matches("<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",text) {
            let raw=group(row,1,text)
            guard !raw.contains(".."),!raw.contains("%"),let url=URL(string:raw,relativeTo:system.indexURL)?.absoluteURL,allowed(url,system:system),url.lastPathComponent != "index.html" else {continue}
            let game=plain(group(row,2,text));guard !game.isEmpty,game.count<=256 else {continue}
            if seen.insert(url).inserted {result.append(.init(game:game,url:url))}
        }
        guard !result.isEmpty,result.count<=1500 else {throw GameGenieCatalog.CatalogError.invalid};return result
    }
    static func page(_ data:Data,link:GameGeniePageLink,system:GameGenieSystem)throws->[GameGenieOfflineCatalog.Entry] {
        let text=try html(data),blocks=try matches("<pre\\b[^>]*>(.*?)</pre>",text)
        guard blocks.count<=8 else {throw GameGenieCatalog.CatalogError.invalid}
        let malformed=blocks.isEmpty
        let content:String
        if malformed {
            guard let fallback=try matches("<!-- NAME -->[^\\n]*\\n(.*?)</pre>",text).first else {throw GameGenieCatalog.CatalogError.invalid}
            content=plain(group(fallback,1,text))
        } else {content=blocks.map{plain(group($0,1,text))}.joined(separator:"\n")}
        guard content.utf8.count<=128*1024 else {throw GameGenieCatalog.CatalogError.invalid}
        let token=system == .nes ? "[APZLGITYEOXUKSVN]{6}(?:[APZLGITYEOXUKSVN]{2})?":"[A-Z0-9]{4}-[A-Z0-9]{4}"
        let codeGroup="\(token)(?:[ \\t]*(?:\\+|/)[ \\t]*\(token))*"
        // Boundaries include embedded numbered entries on one line as well as unnumbered NES rows.
        let pattern="(?m)(?:^[ \\t]*(?:[0-9]+[.)]?[ \\t]+)?|[ \\t]{2,}[0-9]+[.)]?[ \\t]+)(\(codeGroup))[ \\t]+"
        let starts=try matches(pattern,content)
        guard starts.count<=2048 else {throw GameGenieCatalog.CatalogError.invalid}
        let source=link.url.absoluteString
        if starts.isEmpty {
            return [.init(game:link.game,codes:[],title:"Source entry to review",notes:chunks(content),sources:[source],reviewReasons:["No supported code group could be read. Original text is retained."])]
        }
        let ns=content as NSString
        let introduction=String(ns.substring(to:starts[0].range.location)).trimmingCharacters(in:.whitespacesAndNewlines)
        let context=introduction.range(of:"versions?|revisions?|PAL|NTSC|Japan|Europe",options:[.regularExpression,.caseInsensitive]) == nil ? "":String(introduction.prefix(4096))
        // Headings after the first code cannot be safely assigned to a revision by this
        // static importer. Preserve the page and refuse automatic master selection.
        let laterText=ns.substring(from:starts[0].range.location)
        let scopedVersions=laterText.range(of:"(?m)^[ \t]*(?:version|revision|PAL|NTSC|Japan|Europe)\\b",options:[.regularExpression,.caseInsensitive]) != nil
        var result:[GameGenieOfflineCatalog.Entry]=[]
        for (index,row) in starts.enumerated() {
            let raw=group(row,1,content).uppercased(),begin=row.range.location+row.range.length,end=index+1<starts.count ? starts[index+1].range.location:ns.length
            let originalDescription=String(ns.substring(with:NSRange(location:begin,length:end-begin))).trimmingCharacters(in:.whitespacesAndNewlines)
            let description=originalDescription.replacingOccurrences(of:"[ \\t]*\\n[ \\t]*",with:" ",options:.regularExpression)
            let alternatives=raw.components(separatedBy:"/").map{$0.components(separatedBy:"+").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}}
            let codes=alternatives.count==1 ? alternatives[0]:[]
            var reasons:[String]=malformed ? ["The source page has broken formatting. Check the original entry before enabling."]:[]
            if alternatives.count>1 {reasons.append("Choose the code group for your game version; do not enable every alternative.")}
            if !(alternatives.flatMap{$0}).allSatisfy({system.accepts($0)}) {reasons.append("A code has an unrecognized format or type.")}
            if description.isEmpty {reasons.append("The source did not describe this effect.")}
            var notes=chunks(introduction)
            // A code-shaped extra row is not a wrapped prose description. Keep all
            // original bounded text and mark the affected group for human review.
            let extraLines=originalDescription.components(separatedBy:"\n").dropFirst().joined(separator:"\n")
            let unknownRow=extraLines.range(of:"(?m)^[ \t]*(?:[0-9]+[.)]?[ \t]+)?(?:[A-Z0-9]{2,}[-:][A-Z0-9:-]{2,}|[A-Z]{6}(?:[A-Z]{2})?)[ \t]+",options:.regularExpression) != nil
            if unknownRow {reasons.append("Additional code-like text could not be separated. Check the retained original entry.")}
            if description.count>8192 {reasons.append("The source description is unusually long. Its full text is retained in the notes.")}
            if unknownRow || description.count>8192 {notes += chunks(originalDescription)}
            if system == .genesis && scopedVersions {
                reasons.append("This page separates game versions. Master-code relationships need review.")
                notes += chunks(content)
            }
            result.append(.init(game:link.game,codes:codes,title:String((description.isEmpty ? "Effect to review":description).prefix(8192)),context:context,
                alternatives:alternatives.count>1 ? alternatives:[],notes:notes,sources:[source],reviewReasons:reasons))
        }
        if system == .genesis {
            let master=result.filter{$0.title.localizedCaseInsensitiveContains("MASTER CODE")}
            let unambiguous=master.count==1 && master[0].alternatives.isEmpty && !master[0].codes.isEmpty && master[0].reviewReasons.isEmpty && !scopedVersions
            let dependencies=unambiguous ? master[0].codes:[]
            for i in result.indices {
                if result[i].title.localizedCaseInsensitiveContains("MASTER CODE") {result[i].reviewReasons.append("Required master code; included with the game's other effects.")}
                else {
                    result[i].dependencies=dependencies
                    if !master.isEmpty && !unambiguous {
                        result[i].reviewReasons.append("Required master codes have alternatives or version-specific instructions. Review them before choosing codes.")
                        if !scopedVersions {result[i].notes += chunks(content)}
                    }
                }
            }
        }
        return result
    }
    static func chunks(_ value:String)->[String] {
        guard !value.isEmpty else{return []};var text=value,result:[String]=[]
        while !text.isEmpty && result.count<32 {let part=String(text.prefix(4096));result.append(part);text.removeFirst(part.count)}
        return result
    }
}
