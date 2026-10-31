import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESOriginalMenuDiagnosticTests {
    @Test func invalidOrMissingSourcesStopBeforeInputsHostAndUSBFactory() async throws {
        #expect(try await SNESOriginalMenuDiagnostic.runIfPresent(["--unknown-original-menu"]) == nil)
        for args in [["--capture-original-snes-startup","/missing-original-menu","/tmp"],["--capture-original-snes-startup","relative","/tmp"],["--test-original-snes-menu"],["--test-original-snes-menu","relative","/tmp"],["--test-original-snes-menu","/missing-original-menu","/tmp"],["--prepare-original-snes-menu","/missing"]] {
            await #expect(throws:(any Error).self) {
                _=try await SNESOriginalMenuDiagnostic.runIfPresent(args,
                    loadInputs:{Issue.record("Invalid source reached recovery inputs");throw SNESRuntimeBinding.failure()},
                    checkHost:{Issue.record("Invalid source reached host check")},
                    makeIO:{_ in fatalError("Invalid source reached USB factory")})
            }
        }
    }
    @Test func completedAndPartialRunsStayPrivateAndCannotClaimGameplayOrFirmware() async throws {
        guard let menu=try privateOriginalMenu() else {return}
        let pinned=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pinned.fes1,uboot:pinned.uboot,bootImage:pinned.bootImage)
        for fault in ["none","partial","second-report"] {
            let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
            let store=try RecoveryBootSnapshotStore(root:root),prepared=try await store.saveSNESOriginalMenu(menu)
            let io=OriginalMenuFakeIO(menu:menu,fault:fault)
            do {
                let output=try await SNESOriginalMenuDiagnostic.runIfPresent(["--test-original-snes-menu",prepared.path,root.path],loadInputs:{inputs},checkHost:{},makeIO:{_ in io})
                #expect(fault=="none")
                let outputText=try #require(output)
                let json=try #require(JSONSerialization.jsonObject(with:Data(outputText.utf8)) as? [String:Any])
                #expect(json["firmwareWritten"] as? Bool==false)
                let path=URL(fileURLWithPath:try #require(json["directory"] as? String))
                _=try SNESOriginalMenuResult.loadStarted(directory:path,menu:menu)
                let url=path.appendingPathComponent("manifest.json")
                var manifest=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
                #expect(manifest["userGameplayConfirmed"] as? Bool==false && manifest["stockReturnConfirmed"] as? Bool==false)
                manifest["userGameplayConfirmed"]=true;try JSONSerialization.data(withJSONObject:manifest).write(to:url)
                #expect(throws:(any Error).self){try SNESOriginalMenuResult.loadStarted(directory:path,menu:menu)}
            } catch is SNESPreparationDiagnosticSavedError {#expect(fault != "none")}
            let directories=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            for directory in directories {
                let mode=try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber
                #expect(mode?.intValue==0o700)
            }
            #expect((await io.events).filter{$0=="disconnect"}.count==1)
        }
    }
}


extension SNESOriginalMenuDiagnosticTests {
    @Test func captureCommandSavesSeparateEvidenceWithoutMenuEligibility() async throws {
        guard let menu=try privateOriginalMenu() else{return}
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let store=try RecoveryBootSnapshotStore(root:root),prepared=try await store.saveSNESOriginalMenu(menu)
        let pinned=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pinned.fes1,uboot:pinned.uboot,bootImage:pinned.bootImage)
        let io=OriginalMenuFakeIO(menu:menu,fault:"capture-details")
        let text=try #require(try await SNESOriginalMenuDiagnostic.runIfPresent(["--capture-original-snes-startup",prepared.path,root.path],loadInputs:{inputs},checkHost:{},makeIO:{_ in io}))
        let value=try #require(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
        let directory=URL(fileURLWithPath:try #require(value["directory"] as? String))
        #expect(try Data(contentsOf:directory.appendingPathComponent("startup-details.bin"))==startupDetailsFixture())
        #expect(throws:(any Error).self){_=try SNESOriginalMenuResult.loadStarted(directory:directory,menu:menu)}
        let events=await io.events;#expect(!events.contains("launch") && !events.contains("report") && events.filter{$0=="disconnect"}.count==1)
    }
}
