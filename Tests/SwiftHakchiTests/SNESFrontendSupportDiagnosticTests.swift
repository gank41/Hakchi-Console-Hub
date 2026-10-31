import Foundation
import Testing
@testable import SwiftHakchi
struct SNESFrontendSupportDiagnosticTests {
    @Test(arguments:[false,true])
    func evidenceIsPublishedOnlyAfterACompleteClosedCapture(_ fail:Bool) async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let context=String(repeating:"a",count:64),hwid="0123456789abcdef0123456789abcdef"
        let capture=try await SNESFrontendSupportCapture.read(context:context,hwid:hwid,validate:{},read:{frontendSupportFixture($0)})
        do {
            let summary=try #require(try await SNESFrontendSupportDiagnostic.runIfPresent(["--capture-native-snes-frontend-support",root.path,root.path],
                checkHost:{},inventory:{[SNESLibraryContextTests.device()]},collect:{device,_ in
                    if fail {throw CancellationError()}
                    return .init(capture:capture,context:context,hwid:hwid,attachment:device,
                        reports:[Data("first-checked-report".utf8),Data("last-checked-report".utf8)],reportChallenges:[UUID(),UUID()])
                }))
            #expect(!fail)
            let result=try #require(JSONSerialization.jsonObject(with:Data(summary.utf8)) as? [String:Any])
            let output=URL(fileURLWithPath:try #require(result["directory"] as? String))
            #expect(try Data(contentsOf:output.appendingPathComponent("support-0.frame"))==capture.frames[0])
            let manifest=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("manifest.json"))) as? [String:Any])
            #expect(manifest["consoleFilesWritten"] as? Bool == false)
            #expect(manifest["runtimeEligibility"] as? Bool == false)
            #expect((manifest["missingRoles"] as? [String])?.contains("sdl")==true)
            let mode=try FileManager.default.attributesOfItem(atPath:output.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue==0o700)
        } catch {#expect(fail)}
        if fail {#expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)}
    }
    @Test func malformedRequestCannotReachTheUSBInventory() async throws {
        await #expect(throws:(any Error).self) {
            try await SNESFrontendSupportDiagnostic.runIfPresent(["--capture-native-snes-frontend-support","relative","/tmp"],
                checkHost:{Issue.record("unexpected host action")},inventory:{Issue.record("unexpected USB action");return []},
                collect:{_,_ in throw CancellationError()})
        }
    }
}
