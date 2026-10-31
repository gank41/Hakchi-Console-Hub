import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func privateStartupTrial() async throws -> PreparedSNESStartupTrial {
    let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"])
    // Historical receipts must remain paired with the exact historical candidate.
    let candidatePath=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"])
    let c=try SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:candidatePath)),p=try PinnedFELInputs.load()
    return try PreparedSNESStartupTrial.prepare(candidate:c,evidence:URL(fileURLWithPath:path),recovery:.init(fes1:p.fes1,uboot:p.uboot,bootImage:p.bootImage))
}
@Suite(.serialized)
struct SNESStartupTrialTests {
    @Test func decodesFourLittleEndianSIDWordsAndRefusesInvalidIDs() throws {
        #expect(try SNESStartupSID.decode(Data(1...16))=="04030201080706050c0b0a09100f0e0d")
        for b in [Data(),Data(count:15),Data(count:16),Data(count:17)] {#expect(throws:(any Error).self) {try SNESStartupSID.decode(b)}}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func preparesOnlyExactCandidateAndRevalidatesOriginalEvidence() async throws {
        let trial=try await privateStartupTrial();try trial.validateCurrent()
        #expect(trial.image==trial.candidate.image)
        #expect(BackupManifest.digest(trial.image)=="3bc7b08b7e7170caee3b26fc0cd76b7d9e2951d9cad8bd170eb04d57945097a7")
        #expect(BackupManifest.digest(trial.fes1)==RecoveryPayloadValidator.fes1SHA256)
        let p=try PinnedFELInputs.load(),recovery=try RecoveryBootInputs(fes1:p.fes1,uboot:p.uboot,bootImage:p.bootImage).prepare()
        #expect(trial.uboot==recovery.uboot)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil),arguments:["flag","image","header","binding","backup","extra"])
    func refusesEditedReceiptWithoutBootCapability(_ fault:String) async throws {
        let trial=try await privateStartupTrial(),root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let folder=root.appendingPathComponent(trial.evidence.directory.lastPathComponent)
        try FileManager.default.copyItem(at:trial.evidence.directory,to:folder)
        let path=folder.appendingPathComponent("manifest.json")
        var m=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
        switch fault {
        case "flag":m["firmwareInstallEligible"]=true
        case "image":m["imageSHA256"]=String(repeating:"0",count:64)
        case "binding":var b=try #require(m["binding"] as? [String:Any]);b["expectedHWID"]=String(repeating:"1",count:32);m["binding"]=b
        case "backup":m["initialBackupDataSHA256"]=String(repeating:"0",count:64)
        case "header":var b=try Data(contentsOf:folder.appendingPathComponent("data-header.bin"));b[0]^=1;try b.write(to:folder.appendingPathComponent("data-header.bin"))
        default:try Data([1]).write(to:folder.appendingPathComponent("extra"))
        }
        try JSONSerialization.data(withJSONObject:m).write(to:path)
        #expect(throws:(any Error).self) {try SNESStartupPreflightEvidence.load(directory:folder,candidate:trial.candidate)}
    }
}
