import Foundation
import Testing
@testable import SwiftHakchi

struct SNESRAMMenuDiagnosticTests {
    @Test func previewAndTestRequireExplicitInputsAndMatchingApprovalShape() throws {
        let paths = (0..<10).map { "/tmp/input\($0)" }
        let nonce = "BF0E0859-AF24-45B4-A7BA-3AFE4EBD5BAE"
        let previewValue = try SNESRAMMenuDiagnosticOptions.parse(["--preview-alien3-menu-trial"] + paths + [nonce])
        let preview = try #require(previewValue)
        #expect(preview.approvedImageSHA256 == nil)
        let digest = String(repeating: "a", count: 64)
        let runValue = try SNESRAMMenuDiagnosticOptions.parse(["--test-alien3-menu-trial"] + paths + [nonce, digest])
        let run = try #require(runValue)
        #expect(run.approvedImageSHA256 == digest)
        let resetPaths = paths + ["/tmp/temporary-owner"]
        let resetPreviewValue = try SNESRAMMenuDiagnosticOptions.parse(["--preview-alien3-menu-reset-trial"] + resetPaths + [nonce])
        let resetPreview = try #require(resetPreviewValue)
        #expect(resetPreview.resetTrial && resetPreview.approvedImageSHA256 == nil)
        let resetTestValue = try SNESRAMMenuDiagnosticOptions.parse(["--test-alien3-menu-reset-trial"] + resetPaths + [nonce, digest])
        let resetTest = try #require(resetTestValue)
        #expect(resetTest.resetTrial && resetTest.approvedImageSHA256 == digest)
        let signalPaths = resetPaths + ["/tmp/signal-owner"]
        let signalPreviewValue = try SNESRAMMenuDiagnosticOptions.parse(["--preview-alien3-menu-signal-trial"] + signalPaths + [nonce])
        let signalPreview = try #require(signalPreviewValue)
        #expect(signalPreview.signalTrial && signalPreview.approvedImageSHA256 == nil)
        let signalTestValue = try SNESRAMMenuDiagnosticOptions.parse(["--test-alien3-menu-signal-trial"] + signalPaths + [nonce, digest])
        let signalTest = try #require(signalTestValue)
        #expect(signalTest.signalTrial && signalTest.approvedImageSHA256 == digest)
        let savePaths = signalPaths + ["/tmp/save-payload", "/tmp/save-report", "/tmp/save-menu-owner"]
        let savePreviewValue = try SNESRAMMenuDiagnosticOptions.parse(["--preview-simcity-menu-sram-trial"] + savePaths + [nonce])
        let savePreview = try #require(savePreviewValue)
        #expect(savePreview.sramMenuTrial && savePreview.approvedImageSHA256 == nil)
        let saveTestValue = try SNESRAMMenuDiagnosticOptions.parse(["--test-simcity-menu-sram-trial"] + savePaths + [nonce, digest])
        let saveTest = try #require(saveTestValue)
        #expect(saveTest.sramMenuTrial && saveTest.approvedImageSHA256 == digest)
        #expect(throws: (any Error).self) { try SNESRAMMenuDiagnosticOptions.parse(["--test-simcity-menu-sram-trial"] + signalPaths + [nonce, digest]) }
        let reloadPaths = savePaths + ["/tmp/rom", "/tmp/config", "/tmp/owner", "/tmp/reentry"]
        let reloadPreviewValue = try SNESRAMMenuDiagnosticOptions.parse(["--preview-dkc3-menu-sram-trial"] + reloadPaths + [nonce])
        let reloadPreview = try #require(reloadPreviewValue)
        #expect(reloadPreview.dkc3MenuTrial && reloadPreview.approvedImageSHA256 == nil)
        let reloadTestValue = try SNESRAMMenuDiagnosticOptions.parse(["--test-dkc3-menu-sram-trial"] + reloadPaths + [nonce, digest])
        let reloadTest = try #require(reloadTestValue)
        #expect(reloadTest.dkc3MenuTrial && reloadTest.approvedImageSHA256 == digest)
        #expect(throws: (any Error).self) { try SNESRAMMenuDiagnosticOptions.parse(["--test-dkc3-menu-sram-trial"] + savePaths + [nonce, digest]) }
        let zeldaPreviewValue = try SNESRAMMenuDiagnosticOptions.parse(["--preview-zelda-menu-sram-trial"] + reloadPaths + [nonce])
        let zeldaPreview = try #require(zeldaPreviewValue)
        #expect(zeldaPreview.zeldaMenuTrial && zeldaPreview.approvedImageSHA256 == nil)
        let zeldaTestValue = try SNESRAMMenuDiagnosticOptions.parse(["--test-zelda-menu-sram-trial"] + reloadPaths + [nonce, digest])
        let zeldaTest = try #require(zeldaTestValue)
        #expect(zeldaTest.zeldaMenuTrial && zeldaTest.approvedImageSHA256 == digest)
        let unrelated = try SNESRAMMenuDiagnosticOptions.parse(["--unrelated"])
        #expect(unrelated == nil)
        #expect(throws: (any Error).self) { try SNESRAMMenuDiagnosticOptions.parse(["--test-alien3-menu-trial"] + paths + [nonce]) }
        #expect(throws: (any Error).self) { try SNESRAMMenuDiagnosticOptions.parse(["--test-alien3-menu-trial"] + paths + [nonce, "BAD"]) }
        #expect(throws: (any Error).self) { try SNESRAMMenuDiagnosticOptions.parse(["--preview-alien3-menu-trial"] + ["relative"] + paths.dropFirst() + [nonce]) }
    }
}
