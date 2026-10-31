import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESFirmwareTrialProofTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PLAYED"] != nil),arguments:["none","flag","image","phase","report","challenge"])
    func requiresRealPairedRAMReportsWithoutEligibilityFlags(_ fault:String) async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial()
        let started=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_STARTED"]))
        let played=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PLAYED"]))
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let copy=root.appendingPathComponent(played.lastPathComponent);try FileManager.default.copyItem(at:played,to:copy)
        let file=copy.appendingPathComponent("manifest.json");var m=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        switch fault {
        case "flag":m["firmwareInstallEligible"]=true
        case "image":m["imageSHA256"]=String(repeating:"0",count:64)
        case "phase":m["phase"]="started"
        case "report":try Data([1]).write(to:copy.appendingPathComponent("report-1.txt"))
        case "challenge":m["challenges"]=Array(repeating:UUID().uuidString,count:2)
        default:break
        }
        try JSONSerialization.data(withJSONObject:m).write(to:file)
        if fault=="none" {
            let proof=try SNESFirmwareTrialProof.load(started:started,played:copy,trial:trial)
            try proof.revalidate(trial:trial)
            let raw=try Data(contentsOf:file);#expect(proof.playedSHA256==BackupManifest.digest(raw))
        } else {#expect(throws:(any Error).self){try SNESFirmwareTrialProof.load(started:started,played:copy,trial:trial)}}
    }
}
