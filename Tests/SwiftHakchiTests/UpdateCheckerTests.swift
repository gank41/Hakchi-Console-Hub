import Foundation
import Testing
@testable import SwiftHakchi

struct UpdateCheckerTests {
    @Test func selectsNewestPublishedInstallerIncludingPreviews() throws {
        let json = """
        [{"tag_name":"v0.2.1-preview","draft":false,"assets":[{"name":"app.dmg","state":"uploaded"}]},
         {"tag_name":"v0.3.0","draft":true,"assets":[{"name":"app.dmg","state":"uploaded"}]},
         {"tag_name":"v0.2.9","draft":false,"assets":[]},
         {"tag_name":"v0.2.0","draft":false,"assets":[{"name":"app.dmg","state":"uploaded"}]}]
        """
        let release = try UpdateChecker.release(from: Data(json.utf8))
        #expect(release?.tag == "v0.2.1-preview")
        #expect(release?.isNewer(than: "0.2.0") == true)
        #expect(release?.isNewer(than: "0.2.1") == false)
        #expect(release?.isNewer(than: "not-a-version") == nil)
    }
    @Test func noInstallerDoesNotClaimAnUpdateExists() throws {
        let data = Data("[{\"tag_name\":\"v1.0\",\"draft\":false,\"assets\":[]}]".utf8)
        #expect(try UpdateChecker.release(from: data) == nil)
        #expect(throws: (any Error).self) { try UpdateChecker.release(from: Data("invalid".utf8)) }
    }
}
