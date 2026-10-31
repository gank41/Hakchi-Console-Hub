import Foundation
import Testing
@testable import SwiftHakchi
struct GameGenieHTMLImportTests {
    @Test func indexDeduplicatesLinksAndRefusesOtherCheatSections() throws {
        let data=Data("<div><a href='contra.html'>Contra</a><a href='contra.html'>Contra</a><a href='../../nes/no.html'>Bad</a><a href='javascript:no()'>Bad</a></div>".utf8)
        let links=try GameGenieHTMLImport.index(data,system:.nes)
        #expect(links.count==1 && links[0].game=="Contra")
        #expect(!GameGenieHTMLImport.allowed(URL(string:"https://evil.example/cheats/gamegenie/nes/a.html")!,system:.nes))
        #expect(!GameGenieHTMLImport.allowed(URL(string:"https://gamegenie.com/cheats/nes/a.html")!,system:.nes))
    }
    @Test func groupedAlternativesWrappedDescriptionsAndMastersKeepMeaning() throws {
        let snes=Data("<pre id='content'>THERE ARE TWO VERSIONS\n1 C2C9-4E2C / C2C1-4A9C Infinite lives\n2 D9BB-AFA1 + D9CE-6D0D Start with more\nbombs after a new life\n</pre>".utf8)
        let page=GameGeniePageLink(game:"Example",url:URL(string:"https://gamegenie.com/cheats/gamegenie/snes/example.html")!)
        let rows=try GameGenieHTMLImport.page(snes,link:page,system:.snes)
        #expect(rows.count==2)
        #expect(rows[0].alternatives==[["C2C9-4E2C"],["C2C1-4A9C"]] && rows[0].selectableCodes(system:.snes)==nil)
        #expect(rows[1].codes==["D9BB-AFA1","D9CE-6D0D"] && rows[1].title.contains("bombs after"))
        let genesis=Data("<pre>1 ATBT-AA32 MASTER CODE--MUST BE ENTERED\n2 AE3T-AACL One life     3 AY3T-AACL Five lives\n4 XXXX-XXXX Unrecognized effect\n</pre>".utf8)
        let g=try GameGenieHTMLImport.page(genesis,link:page,system:.genesis)
        #expect(g.count==4 && g[1].dependencies==["ATBT-AA32"] && g[2].codes==["AY3T-AACL"])
        #expect(!g[0].reviewReasons.isEmpty)
        #expect(g.allSatisfy{!$0.sources.isEmpty})
    }
    @Test func malformedPagesAndUnknownTextRemainReviewable() throws {
        let page=GameGeniePageLink(game:"Example",url:GameGenieSystem.nes.indexURL.deletingLastPathComponent().appendingPathComponent("example.html"))
        let rows=try GameGenieHTMLImport.page(Data("<pre>Unrecognized code format 1234:FFFF<br>Use on version 2 only.</pre>".utf8),link:page,system:.nes)
        #expect(rows.count==1 && !rows[0].reviewReasons.isEmpty && rows[0].notes.joined().contains("version 2"))
        #expect(throws:(any Error).self){try GameGenieHTMLImport.page(Data("<html>No content</html>".utf8),link:page,system:.nes)}
        #expect(throws:(any Error).self){try GameGenieHTMLImport.index(Data(repeating:0,count:2*1024*1024+1),system:.nes)}
    }
}

extension GameGenieHTMLImportTests {
    @Test func malformedOpeningMarkupRetainsCodesButRequiresReview() throws {
        let page=GameGeniePageLink(game:"Example",url:GameGenieSystem.nes.indexURL.deletingLastPathComponent().appendingPathComponent("example.html"))
        let rows=try GameGenieHTMLImport.page(Data("<!-- NAME --><b>Example</H3\nSXIOPO Example effect\nGZUXNGEI Another effect\n</pre><!-- /TEXT -->".utf8),link:page,system:.nes)
        #expect(rows.count==2 && rows[0].codes==["SXIOPO"] && !rows[0].reviewReasons.isEmpty)
    }
}

extension GameGenieHTMLImportTests {
    @Test func mixedUnknownRowsAndLongDescriptionsRequireReviewWithoutLosingText() throws {
        let page=GameGeniePageLink(game:"Example",url:GameGenieSystem.nes.indexURL)
        let mixed=try GameGenieHTMLImport.page(Data("<pre>SXIOPO Infinite lives\n1234:FFFF Unrecognized extra code</pre>".utf8),link:page,system:.nes)
        #expect(mixed[0].selectableCodes(system:.nes)==nil)
        #expect(!mixed[0].reviewReasons.isEmpty && mixed[0].notes.joined().contains("1234:FFFF"))
        let long=String(repeating:"long description ",count:700)+"RETAIN THE END"
        let rows=try GameGenieHTMLImport.page(Data(("<pre>SXIOPO "+long+"</pre>").utf8),link:page,system:.nes)
        #expect(rows[0].selectableCodes(system:.nes)==nil)
        #expect(rows[0].notes.joined().contains("RETAIN THE END"))
    }
    @Test func uncertainGenesisMastersCannotBeDroppedOrCombinedAcrossVersions() throws {
        let page=GameGeniePageLink(game:"Example",url:GameGenieSystem.genesis.indexURL)
        let alternatives=try GameGenieHTMLImport.page(Data("<pre>1 ATBT-AA32 / GJ6A-CA7A MASTER CODE\n2 AE3T-AACL One life</pre>".utf8),link:page,system:.genesis)
        #expect(alternatives[1].selectableCodes(system:.genesis)==nil)
        let scoped=try GameGenieHTMLImport.page(Data("<pre>Version 1\n1 ATBT-AA32 MASTER CODE\n2 AE3T-AACL One life\nVersion 2\n3 GJ6A-CA7A MASTER CODE\n4 AY3T-AACL Five lives</pre>".utf8),link:page,system:.genesis)
        #expect(scoped.allSatisfy{$0.selectableCodes(system:.genesis)==nil})
        #expect(scoped.allSatisfy{$0.dependencies.isEmpty})
        #expect(scoped.flatMap(\.notes).joined().contains("Version 2"))
    }
}
