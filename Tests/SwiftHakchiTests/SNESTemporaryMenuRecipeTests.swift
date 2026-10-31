import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func privateTemporaryMenu() throws -> PreparedSNESTemporaryMenu? {
    guard let support = try privateMenuSupportMaterial() else { return nil }
    let env = ProcessInfo.processInfo.environment
    guard let runtimePath = env["SWIFTHAKCHI_SNES_RUNTIME"], let kernel = env["SWIFTHAKCHI_SNES_KERNEL"],
          let hmod = env["SWIFTHAKCHI_SNES_CLOVERSHELL"], let bb = env["SWIFTHAKCHI_SNES_BUSYBOX"],
          let drivers = env["SWIFTHAKCHI_SNES_DRIVERS"] else { return nil }
    let runtime = try SNESRuntimeMaterial.load(directory: URL(fileURLWithPath: runtimePath), source: support.setup)
    let pinned = try PinnedFELInputs.load()
    let base = try SNESRAMProbeRecipe.prepare(source: support.setup, runtime: runtime,
        kernel: Data(contentsOf: URL(fileURLWithPath: kernel)), hmod: Data(contentsOf: URL(fileURLWithPath: hmod)),
        busybox: Data(contentsOf: URL(fileURLWithPath: bb)),
        recovery: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage), nonce: "33333333-3333-3333-3333-333333333333")
    return try SNESTemporaryMenuRecipe.prepare(base: base, support: support, drivers: SNESMenuDrivers(Data(contentsOf: URL(fileURLWithPath: drivers))), nonce: UUID(uuidString: menuNonce)!)
}
@Suite(.serialized)
struct SNESTemporaryMenuRecipeTests {
    @Test func sealedImagePreservesOriginalMembersAndExportsOnlyTemporaryPurpose() throws {
        guard let menu = try privateTemporaryMenu() else { return }
        try menu.validateCurrent()
        let image = try LegacyBootImageBuilder.inspect(menu.image)
        let original = try LegacyBootImageBuilder.inspect(menu.support.setup.stock)
        for entry in original.archive.entries where entry.name != "init" {
            var expected = entry
            if entry.name == "." { expected.fields[4] += 1 }
            #expect(image.archive.entries.first { $0.name == entry.name } == expected)
        }
        #expect(image.archive.entries.filter { $0.name.hasSuffix(".ko") }.count == 4)
        #expect(image.archive.entries.first { $0.name == "probe/source-files.sha256" }?.data == Data(menu.support.sourceFiles.utf8))
        let exported = try menu.checkedExport()
        let m = try #require(JSONSerialization.jsonObject(with: exported.manifest) as? [String: Any])
        #expect(m["scope"] as? String == "snes-temporary-menu-image")
        #expect(m["firmwareRestoreEligible"] as? Bool == false)
        #expect(m["firmwareWritten"] as? Bool == false)
    }
    @Test func savedImageReconstructsAndRejectsChangedRecipeEvenWithEditedHash() async throws {
        guard let menu = try privateTemporaryMenu() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = try await RecoveryBootSnapshotStore(root: root).saveSNESTemporaryMenu(menu)
        let pinned = try PinnedFELInputs.load(), inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        #expect(try SNESTemporaryMenuRecipe.load(directory: path, recovery: inputs).image == menu.image)
        var image = menu.image; image[2048] ^= 1
        try image.write(to: path.appendingPathComponent("menu.img"))
        var m = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("manifest.json"))) as? [String: Any])
        m["imageSHA256"] = BackupManifest.digest(image)
        try JSONSerialization.data(withJSONObject: m).write(to: path.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try SNESTemporaryMenuRecipe.load(directory: path, recovery: inputs) }
    }
}

@Suite(.serialized)
struct SNESTemporaryMenuEvidenceTests {
    @Test func savedMachineReportCannotClaimUserGameplayAndRejectsEditedReceipt() async throws {
        guard let menu = try privateTemporaryMenu() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let challenges = [UUID(), UUID()]
        let reports = challenges.map { challenge in
            Data(String(decoding: menuReport(challenge: challenge), as: UTF8.self)
                .replacingOccurrences(of: runtimeBindingFixture().expectedHWID, with: menu.binding.expectedHWID)
                .replacingOccurrences(of: String(repeating: "a", count: 64), with: menu.filesSHA256)
                .replacingOccurrences(of: String(repeating: "b", count: 64), with: menu.sourceFilesSHA256).utf8)
        }
        let result = SNESTemporaryMenuResult(before: probeFEL(), after: temporaryMenuUSB(), challenges: challenges, reports: reports, phase: "started")
        let store = try RecoveryBootSnapshotStore(root: root), path = try await store.saveSNESTemporaryMenuResult(result, menu: menu)
        #expect(try SNESTemporaryMenuResult.loadStarted(directory: path, menu: menu).reports == reports)
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["userGameplayConfirmed"] as? Bool == false && manifest["stockReturnConfirmed"] as? Bool == false)
        manifest["userGameplayConfirmed"] = true
        try JSONSerialization.data(withJSONObject: manifest).write(to: path.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try SNESTemporaryMenuResult.loadStarted(directory: path, menu: menu) }
        let failure = SNESTemporaryMenuFailure(stage: "live-menu-report", report: Data("partial".utf8), diagnostics: Data())
        let failed = try await store.saveSNESTemporaryMenuFailure(failure, menu: menu)
        let m = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: failed.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(m["complete"] as? Bool == false && m["firmwareWritten"] as? Bool == false)
        #expect(try Data(contentsOf: failed.appendingPathComponent("partial-report.txt")) == Data("partial".utf8))
    }
    @Test func sourceChangedDuringHostAwaitCannotReachUSBFactory() async throws {
        guard let original = try privateTemporaryMenu() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent(original.support.directoryURL.lastPathComponent)
        try FileManager.default.copyItem(at: original.support.directoryURL, to: copy)
        let support = try SNESMenuSupportMaterial.load(source: original.support.source, directory: copy)
        let menu = try SNESTemporaryMenuRecipe.prepare(base: original.base, support: support, drivers: original.drivers)
        let saved = try await RecoveryBootSnapshotStore(root: root).saveSNESTemporaryMenu(menu)
        let pinned = try PinnedFELInputs.load()
        await #expect(throws: (any Error).self) {
            try await SNESTemporaryMenuDiagnostic.runIfPresent(["--test-snes-menu", saved.path],
                loadInputs: { .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage) },
                checkHost: { try Data([0]).write(to: copy.appendingPathComponent("support.frame")) },
                makeIO: { _ in Issue.record("Changed source reached USB construction"); return TemporaryMenuFakeIO() })
        }
    }
}

extension SNESTemporaryMenuRecipeTests {
    @Test func preparingANewMenuUsesAFreshNonceInsteadOfThePriorProbeNonce() throws {
        guard let original = try privateTemporaryMenu() else { return }
        let fresh = try SNESTemporaryMenuRecipe.prepare(base: original.base, support: original.support, drivers: original.drivers)
        #expect(fresh.nonce != original.nonce)
        #expect(fresh.image != original.image)
    }
}

extension SNESTemporaryMenuEvidenceTests {
    @Test(arguments: ["closing", "before-manifest"])
    func changedSourceAtCompletionPreservesBothReportsWithoutSuccess(boundary: String) async throws {
        guard let original = try privateTemporaryMenu() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent(original.support.directoryURL.lastPathComponent)
        try FileManager.default.copyItem(at: original.support.directoryURL, to: copy)
        let support = try SNESMenuSupportMaterial.load(source: original.support.source, directory: copy)
        let menu = try SNESTemporaryMenuRecipe.prepare(base: original.base, support: support, drivers: original.drivers)
        let io = TemporaryMenuFakeIO(expected: menu.expectation)
        if boundary == "closing" {
            let saved = try await RecoveryBootSnapshotStore(root: root).saveSNESTemporaryMenu(menu)
            let pinned = try PinnedFELInputs.load()
            await #expect(throws: (any Error).self) {
                try await SNESTemporaryMenuDiagnostic.runIfPresent(["--test-snes-menu", saved.path],
                    loadInputs: { .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage) },
                    checkHost: {}, makeIO: { _ in io }, progress: { event in
                        if event == .closing { try? Data([1]).write(to: copy.appendingPathComponent("support.frame")) }
                    })
            }
            #expect(await io.counts() == [1,2,1])
            let failures = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("SNES-Temporary-Menu-Diagnostic-") }
            #expect(failures.count == 1)
            if let failure = failures.first {
                let m = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: failure.appendingPathComponent("manifest.json"))) as? [String: Any])
                #expect(m["complete"] as? Bool == false)
                for index in 0..<2 { #expect(try Data(contentsOf: failure.appendingPathComponent("report-\(index).txt")).starts(with: Data("SWIFTHAKCHI_SNES_MENU_REPORT_V1\n".utf8))) }
            }
        } else {
            let result = try await SNESTemporaryMenuService(wait: {}).start(expected: menu.expectation, io: io, validate: {})
            let store = try RecoveryBootSnapshotStore(root: root, synchronize: { fd in
                try? Data([1]).write(to: copy.appendingPathComponent("support.frame")); return fsync(fd)
            })
            await #expect(throws: (any Error).self) { try await store.saveSNESTemporaryMenuResult(result, menu: menu) }
            let partial = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("SNES-Temporary-Menu-Result-") }
            #expect(partial.count == 1)
            let directory = try #require(partial.first)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
            for index in 0..<2 { #expect(try Data(contentsOf: directory.appendingPathComponent("report-\(index).txt")) == result.reports[index]) }
        }
    }
}

@Suite(.serialized)
struct SNESTemporaryMenuStartAuthorityTests {
    @Test func changedRecipeSourceCannotSendTheRAMStartupCommand() async throws {
        guard let original = try privateTemporaryMenu() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent(original.support.directoryURL.lastPathComponent)
        try FileManager.default.copyItem(at: original.support.directoryURL, to: copy)
        let support = try SNESMenuSupportMaterial.load(source: original.support.source, directory: copy)
        let menu = try SNESTemporaryMenuRecipe.prepare(base: original.base, support: support, drivers: original.drivers)
        let request = SNESTemporaryMenuStartRequest(menu: menu, challenge: menuChallenge)
        let usb = LegacyFakeUSB(), client = LegacyInspectionClient(transport: usb)
        try await client.connect()
        try Data([0]).write(to: copy.appendingPathComponent("support.frame"))
        await #expect(throws: (any Error).self) { try await client.startTemporarySNESMenu(request) }
        #expect(await usb.execPayloads.isEmpty)
        await client.disconnect()
    }
}
