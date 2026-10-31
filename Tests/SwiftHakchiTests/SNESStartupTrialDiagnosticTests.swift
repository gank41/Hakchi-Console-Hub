import Foundation
import Testing
@testable import SwiftHakchi

struct SNESStartupTrialDiagnosticTests {
    @Test func unrelatedModeDoesNotLoadOrConstructAnything() async throws {
        let value=try await SNESStartupTrialDiagnostic.runIfPresent(["--other"],loadInputs:{Issue.record("Unexpected load");throw SNESRuntimeBinding.failure()},checkHost:{Issue.record("Unexpected host check")},makeIO:{_ in Issue.record("Unexpected IO");throw SNESRuntimeBinding.failure()})
        #expect(value==nil)
    }
    @Test(arguments:[["--test-snes-startup"],["--check-snes-startup","relative","/tmp"],["--test-snes-startup","/missing","/missing","/missing"]])
    func invalidPathsRefuseBeforeUSBConstruction(_ args:[String]) async {
        await #expect(throws:(any Error).self) {try await SNESStartupTrialDiagnostic.runIfPresent(args,loadInputs:{Issue.record("Unexpected load");throw SNESRuntimeBinding.failure()},checkHost:{Issue.record("Unexpected host check")},makeIO:{_ in Issue.record("Unexpected IO");throw SNESRuntimeBinding.failure()})}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"] != nil && ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func savesStartedAndAfterGameReceiptsWithoutInstallAuthority() async throws {
        let env=ProcessInfo.processInfo.environment,candidate=try #require(env["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"]),evidence=try #require(env["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"])
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let p=try PinnedFELInputs.load()
        let inputs: @Sendable () async throws -> RecoveryBootInputs={.init(fes1:p.fes1,uboot:p.uboot,bootImage:p.bootImage)}
        let start=try await SNESStartupTrialDiagnostic.runIfPresent(["--test-snes-startup",candidate,evidence,root.path],loadInputs:inputs,checkHost:{},makeIO:{try StartupTrialSessionFake(expected:.checked($0),fault:"none")})
        let startText=try #require(start)
        let object=try #require(JSONSerialization.jsonObject(with:Data(startText.utf8)) as? [String:Any]),path=try #require(object["directory"] as? String)
        let check=try await SNESStartupTrialDiagnostic.runIfPresent(["--check-snes-startup",candidate,evidence,path,root.path],loadInputs:inputs,checkHost:{},makeIO:{try StartupTrialSessionFake(expected:.checked($0),fault:"none",booted:true)})
        let afterText=try #require(check)
        let after=try #require(JSONSerialization.jsonObject(with:Data(afterText.utf8)) as? [String:Any])
        #expect(after["complete"] as? Bool==true && after["firmwareWritten"] as? Bool==false)
        let saved=URL(fileURLWithPath:try #require(after["directory"] as? String))
        let m=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:saved.appendingPathComponent("manifest.json"))) as? [String:Any])
        #expect(m["phase"] as? String=="after-gameplay" && m["firmwareInstallEligible"] as? Bool==false && m["userGameplayConfirmed"] as? Bool==false)
        #expect(throws:(any Error).self) {try SNESStartupTrialResult.loadStarted(directory:saved,trial:PreparedSNESStartupTrial.prepare(candidate:SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:candidate)),evidence:URL(fileURLWithPath:evidence),recovery:inputsSync(p)))}
    }
}
private func inputsSync(_ p:PinnedFELInputs)->RecoveryBootInputs {.init(fes1:p.fes1,uboot:p.uboot,bootImage:p.bootImage)}
