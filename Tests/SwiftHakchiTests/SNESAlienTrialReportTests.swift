import Foundation
import Testing
@testable import SwiftHakchi

struct SNESAlienTrialReportTests {
    let nonce = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let challenge = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
    let hash = String(repeating: "a", count: 64)
    func frame() -> String {
        "SWIFTHAKCHI_SNES_TRIAL_V1\nNONCE=\(nonce.uuidString)\nCHALLENGE=\(challenge.uuidString)\nSTATUS=running\nTRIAL_PID=123\nDAEMON_PID=456\nEXEC_SHA=\(hash)\nEND\n"
    }
    @Test func acceptsBoundRunningProcess() throws {
        let report = try SNESAlienTrialReport(Data(frame().utf8), nonce: nonce, challenge: challenge, expectedExecutableSHA256: hash)
        #expect(report.pid == 123)
        #expect(LegacyReadRequest.snesAlienTrialReport(challenge: challenge).command == "exec /probe/busybox sh /probe/trial-report " + challenge.uuidString)
    }
    @Test(arguments: ["nonce", "challenge", "status", "pid", "samepid", "hash", "duplicate", "trailing", "oversized"])
    func rejectsUnboundAndMalformedFrames(fault: String) {
        var text = frame()
        switch fault {
        case "nonce": text = text.replacingOccurrences(of: nonce.uuidString, with: UUID().uuidString)
        case "challenge": text = text.replacingOccurrences(of: challenge.uuidString, with: UUID().uuidString)
        case "status": text = text.replacingOccurrences(of: "STATUS=running", with: "STATUS=ready")
        case "pid": text = text.replacingOccurrences(of: "TRIAL_PID=123", with: "TRIAL_PID=01")
        case "samepid": text = text.replacingOccurrences(of: "TRIAL_PID=123", with: "TRIAL_PID=456")
        case "hash": text = text.replacingOccurrences(of: hash, with: String(repeating: "b", count: 64))
        case "duplicate": text = text.replacingOccurrences(of: "STATUS=running\n", with: "STATUS=running\nSTATUS=running\n")
        case "trailing": text += "extra\n"
        default: text += String(repeating: "x", count: 8192)
        }
        #expect(throws: (any Error).self) { _ = try SNESAlienTrialReport(Data(text.utf8), nonce: nonce, challenge: challenge, expectedExecutableSHA256: hash) }
    }
}
