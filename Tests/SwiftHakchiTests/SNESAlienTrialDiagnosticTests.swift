import Foundation
import Testing
@testable import SwiftHakchi

struct SNESAlienTrialDiagnosticTests {
    @Test func argumentsRequireExactPreviewIdentityAndAbsolutePaths() throws {
        #expect(try SNESAlienTrialDiagnosticOptions.parse(["--unrelated"]) == nil)
        let nonce = "11111111-2222-4333-8444-555555555555"
        let paths = (1...9).map { "/fixture/\($0)" }
        let digest = String(repeating: "a", count: 64)
        let preview = ["--preview-alien3-trial"] + paths + [nonce]
        let run = ["--test-alien3-trial"] + paths + [nonce, digest]
        #expect(try SNESAlienTrialDiagnosticOptions.parse(preview) != nil)
        #expect(try SNESAlienTrialDiagnosticOptions.parse(run) != nil)
        #expect(try SNESAlienTrialDiagnosticOptions.parse(["--preview-alien3-power-trial"] + paths + [nonce])?.powerTrial == true)
        #expect(try SNESAlienTrialDiagnosticOptions.parse(["--test-alien3-power-trial"] + paths + [nonce, digest])?.powerTrial == true)
        #expect(try SNESAlienTrialDiagnosticOptions.parse(["--preview-alien3-reset-trial"] + paths + [nonce])?.resetTrial == true)
        #expect(try SNESAlienTrialDiagnosticOptions.parse(["--test-alien3-reset-trial"] + paths + [nonce, digest])?.resetTrial == true)
        #expect(try SNESAlienTrialDiagnosticOptions.parse(["--preview-simcity-sram-trial"] + paths + [nonce])?.sramTrial == true)
        #expect(try SNESAlienTrialDiagnosticOptions.parse(["--test-simcity-sram-trial"] + paths + [nonce, digest])?.sramTrial == true)
        let missingNonce = Array(preview.dropLast())
        let missingDigest = ["--test-alien3-trial"] + paths + [nonce]
        let invalidDigest = ["--test-alien3-trial"] + paths + [nonce, "bad"]
        let relativePaths = ["relative"] + Array(paths.dropFirst())
        let relativePath = ["--preview-alien3-trial"] + relativePaths + [nonce]
        let invalidNonce = ["--preview-alien3-trial"] + paths + ["bad"]
        let invalidArguments: [[String]] = [missingNonce, missingDigest, invalidDigest, relativePath, invalidNonce]
        for bad in invalidArguments {
            #expect(throws: (any Error).self) { _ = try SNESAlienTrialDiagnosticOptions.parse(bad) }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_TRIAL_MENU_DIRECTORY"] != nil && ProcessInfo.processInfo.environment["HC_TRIAL_PAYLOAD"] != nil && ProcessInfo.processInfo.environment["HC_TRIAL_REPORT"] != nil, "Requires private SNES recovery and trial files"))
    func previewAndSimulatedRunUseTheSameImage() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: try #require(env["HC_TRIAL_MENU_DIRECTORY"]))
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("manifest.json"))) as? [String: Any])
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = try ["setupPath", "preparationPath", "supportPath", "componentsPath", "runtimePath"].map { try #require(saved[$0] as? String) } +
            [base.appendingPathComponent("original-menu.img").path, try #require(env["HC_TRIAL_PAYLOAD"]), try #require(env["HC_TRIAL_REPORT"]), root.path]
        let nonce = UUID().uuidString
        let power = env["HC_TRIAL_POWER"] == "1"
        let reset = env["HC_TRIAL_RESET"] == "1"
        let sram = env["HC_TRIAL_SRAM"] == "1"
        let previewCommand = sram ? "--preview-simcity-sram-trial" : reset ? "--preview-alien3-reset-trial" : (power ? "--preview-alien3-power-trial" : "--preview-alien3-trial")
        let testCommand = sram ? "--test-simcity-sram-trial" : reset ? "--test-alien3-reset-trial" : (power ? "--test-alien3-power-trial" : "--test-alien3-trial")
        let previewText = try #require(try await SNESAlienTrialDiagnostic.runIfPresent([previewCommand] + paths + [nonce]))
        let json = try #require(JSONSerialization.jsonObject(with: Data(previewText.utf8)) as? [String: Any])
        let hash = try #require(json["imageSHA256"] as? String)
        let testText = try #require(try await SNESAlienTrialDiagnostic.runIfPresent([testCommand] + paths + [nonce, hash], checkHost: {}, makeIO: { AlienTrialFakeIO(trial: $0) }))
        let result = try #require(JSONSerialization.jsonObject(with: Data(testText.utf8)) as? [String: Any])
        #expect(result["gameplayConfirmed"] as? Bool == false)
        #expect(result["firmwareWritten"] as? Bool == false)
        await #expect(throws: (any Error).self) {
            _ = try await SNESAlienTrialDiagnostic.runIfPresent([testCommand] + paths + [nonce, String(repeating: "0", count: 64)], checkHost: {}, makeIO: { AlienTrialFakeIO(trial: $0) })
        }
    }

}
