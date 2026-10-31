import Foundation
import Testing
@testable import SwiftHakchi

struct SNESCompatibilitySupportDiagnosticTests {
    @Test(arguments:[["--capture-native-snes-support"],["--capture-native-snes-support","relative","/tmp"],
                     ["--capture-native-snes-support","/tmp","/tmp","--install"]])
    func malformedRequestCannotOpenUSB(_ args:[String]) async {
        await #expect(throws:(any Error).self) {
            try await SNESCompatibilitySupportDiagnostic.runIfPresent(args,
                checkHost:{Issue.record("unexpected host check")},inventory:{Issue.record("unexpected USB access");return []})
        }
    }
    @Test(arguments:[false,true])
    func completedCaptureIsPublishedPrivatelyAndFailurePublishesNothing(_ fail:Bool) async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let context=String(repeating:"a",count:64),hwid="0123456789abcdef0123456789abcdef"
        let capture=try await SNESCompatibilitySupportCapture.read(context:context,hwid:hwid,validate:{},read:{nonce in
            var raw=compatibilitySupportFixture()
            raw.replaceSubrange(raw.range(of:Data("11111111-1111-1111-1111-111111111111".utf8))!,with:Data(nonce.uuidString.utf8));return raw
        })
        do {
            let summary=try #require(try await SNESCompatibilitySupportDiagnostic.runIfPresent(["--capture-native-snes-support",root.path,root.path],
                checkHost:{},inventory:{[SNESLibraryContextTests.device()]},collect:{device,_ in
                    if fail {throw CancellationError()}
                    return .init(capture:capture,context:context,hwid:hwid,attachment:device,
                        reports:[Data("first-validated-report".utf8),Data("last-validated-report".utf8)],reportChallenges:[UUID(),UUID()])
                }))
            #expect(!fail)
            let result=try #require(JSONSerialization.jsonObject(with:Data(summary.utf8)) as? [String:Any])
            let output=URL(fileURLWithPath:try #require(result["directory"] as? String))
            #expect(try Data(contentsOf:output.appendingPathComponent("support-0.frame"))==capture.frames[0])
            #expect(try String(contentsOf:output.appendingPathComponent("fb-size.txt"),encoding:.utf8)=="1280,720\n")
            let manifest=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("manifest.json"))) as? [String:Any])
            #expect(manifest["consoleFilesWritten"] as? Bool == false)
            #expect(manifest["firmwareWritten"] as? Bool == false)
            let mode=try FileManager.default.attributesOfItem(atPath:output.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue==0o700)
        } catch {#expect(fail)}
        if fail {#expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)}
    }
    @Test func recoveryModeIsRejectedWithoutCreatingAnOutput() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        await #expect(throws:(any Error).self) {
            try await SNESCompatibilitySupportDiagnostic.runIfPresent(["--capture-native-snes-support",root.path,root.path],
                checkHost:{},inventory:{[probeFEL()]})
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
}
