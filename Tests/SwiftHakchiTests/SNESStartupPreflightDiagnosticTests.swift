import Foundation
import Testing
@testable import SwiftHakchi

struct SNESStartupPreflightDiagnosticTests {
    @Test func unrelatedModeReturnsNilWithoutLoadingAnything() async throws {
        let value=try await SNESStartupPreflightDiagnostic.runIfPresent(["--other"],loadInputs:{Issue.record("Unexpected payload load");throw SNESRuntimeBinding.failure()},checkHost:{Issue.record("Unexpected host check")},makeIO:{_ in Issue.record("Unexpected USB construction");throw SNESRuntimeBinding.failure()})
        #expect(value==nil)
    }
    @Test(arguments:[["--preflight-snes-startup"],["--preflight-snes-startup","relative","/tmp"],["--preflight-snes-startup","/missing","/missing"]])
    func invalidArgumentsRefuseBeforeHardwareConstruction(_ arguments:[String]) async {
        await #expect(throws:(any Error).self) {
            try await SNESStartupPreflightDiagnostic.runIfPresent(arguments,loadInputs:{Issue.record("Unexpected payload load");throw SNESRuntimeBinding.failure()},checkHost:{Issue.record("Unexpected host check")},makeIO:{_ in Issue.record("Unexpected USB construction");throw SNESRuntimeBinding.failure()})
        }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"] != nil),arguments:["none","older-backup"])
    func successfulFakeRunSavesNonEligibleReceipt(_ fault:String) async throws {
        let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"])
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let pinned=try PinnedFELInputs.load()
        let value=try await SNESStartupPreflightDiagnostic.runIfPresent(["--preflight-snes-startup",path,root.path],
            loadInputs:{.init(fes1:pinned.fes1,uboot:pinned.uboot,bootImage:pinned.bootImage)},checkHost:{},makeIO:{try SNESStartupPreflightFakeIO(candidate:$0,fault:fault)})
        let text=try #require(value),object=try #require(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
        #expect(object["firmwareWritten"] as? Bool==false && object["complete"] as? Bool==true)
        let saved=URL(fileURLWithPath:try #require(object["directory"] as? String))
        let receipt=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:saved.appendingPathComponent("manifest.json"))) as? [String:Any])
        #expect(receipt["scope"] as? String=="snes-startup-no-flash-preflight")
        #expect(receipt["backupMatchesCheckedData"] as? Bool==(fault=="none"))
        #expect(receipt["bootEligible"] as? Bool==false && receipt["firmwareInstallEligible"] as? Bool==false)
    }
}
