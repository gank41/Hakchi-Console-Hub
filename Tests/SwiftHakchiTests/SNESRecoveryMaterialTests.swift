import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil, "Requires a private SNES setup fixture"))
struct SNESRecoveryMaterialTests {
    func snapshot(_ root: URL, hwid: String) throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] else { return nil }
        let copy = root.appendingPathComponent("SNES-US-Setup-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        let url = copy.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var capture = try #require(manifest["capture"] as? [String: Any])
        var kernel = try #require(capture["kernel"] as? [String: Any])
        var observation = try #require(kernel["observation"] as? [String: Any])
        observation["hwid"] = hwid; kernel["observation"] = observation; capture["kernel"] = kernel; manifest["capture"] = capture
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        return copy
    }
    @Test func boundsRoundToEraseUnitsWithoutAuthorizingAWrite() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let setup = try snapshot(root, hwid: String(repeating: "1", count: 32)) else { return }
        let material = try SNESRecoveryMaterial.load(setup: setup)
        #expect(try material.bounds.checkedExtent(byteCount: 2_736_128) == 0x600000..<0x8a0000)
        #expect(try material.bounds.checkedExtent(byteCount: 7_340_032) == 0x600000..<0xd00000)
        for count in [-1, 0, 7_340_033, Int.max] {
            #expect(throws: (any Error).self) { try material.bounds.checkedExtent(byteCount: count) }
        }
        let malformed = Data(String(decoding: material.partitions, as: UTF8.self).replacingOccurrences(of: "32768", with: "10000").utf8)
        #expect(throws: (any Error).self) { try SNESBoot2Bounds(partitions: malformed) }
    }
    @Test func eachOwnersConsoleUsesItsOwnCapturedIdentity() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for id in [String(repeating: "1", count: 32), String(repeating: "2", count: 32)] {
            guard let setup = try snapshot(root, hwid: id) else { return }
            let material = try SNESRecoveryMaterial.load(setup: setup)
            #expect(material.expectedHWID == id)
            #expect(throws: (any Error).self) { try material.requireHardwareID(String(repeating: "3", count: 32)) }
            try material.requireHardwareID(id)
        }
    }
    @Test func portablePackageSurvivesMoveAndOriginalSourceRemoval() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let setup = try snapshot(root, hwid: String(repeating: "2", count: 32)) else { return }
        let material = try SNESRecoveryMaterial.load(setup: setup)
        let saved = try await RecoveryBootSnapshotStore(root: root).saveSNESRecoveryMaterial(material)
        try FileManager.default.removeItem(at: setup)
        let otherFolder = root.appendingPathComponent("Other Backup Folder")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: false)
        let moved = otherFolder.appendingPathComponent(saved.lastPathComponent)
        try FileManager.default.moveItem(at: saved, to: moved)
        let reopened = try SNESRecoveryMaterial.loadPackage(directory: moved)
        #expect(reopened.expectedHWID == String(repeating: "2", count: 32))
        #expect(reopened.stock == material.stock)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: moved.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["firmwareRestoreEligible"] as? Bool == false)
        #expect(manifest["firmwareWritten"] as? Bool == false)
        for name in ["active-boot2.img", "boot1.bin", "partitions.txt", "data-header.bin", "recovery-review.json", "manifest.json"] {
            let url = moved.appendingPathComponent(name), original = try Data(contentsOf: url)
            try Data("bad".utf8).write(to: url)
            #expect(throws: (any Error).self) { try reopened.revalidate() }
            #expect(throws: (any Error).self) { try SNESRecoveryMaterial.loadPackage(directory: moved) }
            try original.write(to: url)
        }
        let file = moved.appendingPathComponent("active-boot2.img"), target = root.appendingPathComponent("linked-image")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: (any Error).self) { try SNESRecoveryMaterial.loadPackage(directory: moved) }
    }
}

struct ConsoleRestoreChoiceTests {
    @Test func builtInOnlyDoesNotEraseSavesOrMacLibrary() {
        let effects = ConsoleRestoreChoice.returnToBuiltInGames.effects
        #expect(effects.removesAddedGames && !effects.modifiesStartup && !effects.erasesSavesAndSettings && !effects.changesMacLibrary)
        #expect(ConsoleRestoreChoice.restoreOriginalStartup.effects.modifiesStartup)
        #expect(!ConsoleRestoreChoice.restoreOriginalStartup.effects.erasesSavesAndSettings)
        #expect(ConsoleRestoreChoice.eraseSavesAndSettings.effects.erasesSavesAndSettings)
        #expect(ConsoleRestoreChoice.allCases.allSatisfy { $0.effects.requiresCurrentDeviceBackup && !$0.effects.changesMacLibrary })
    }
}

extension SNESRecoveryMaterialTests {
    @Test @MainActor func appBuildsAndVerifiesRecoveryPackageWithoutChangingTheSavedSetup() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let setup = try snapshot(root, hwid: String(repeating: "7", count: 32)) else { return }
        let manifest = try Data(contentsOf: setup.appendingPathComponent("manifest.json"))
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .snesUsa
        try FileManager.default.createDirectory(at: config.workspace.backups, withIntermediateDirectories: true)
        let app = AppState(startDeviceMonitoring: false, deviceManager: DeviceManager(),
                           gameManager: GameManagerService(config: config), config: config, saveConfiguration: {})
        let before = try FileManager.default.contentsOfDirectory(atPath: config.workspace.backups.path)
        await #expect(throws: (any Error).self) {
            try await app.prepareSNESRecoveryPackage(from: SNESSetupRecordReceipt(kind: .backup, directory: setup, manifestSHA256: String(repeating: "0", count: 64)))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: config.workspace.backups.path) == before)
        let destination = try await app.prepareSNESRecoveryPackage(from: SNESSetupRecordReceipt(kind: .backup, directory: setup, manifestSHA256: BackupManifest.digest(manifest)))
        #expect(try SNESRecoveryMaterial.loadPackage(directory: destination).expectedHWID == String(repeating: "7", count: 32))
        #expect(try Data(contentsOf: setup.appendingPathComponent("manifest.json")) == manifest)
        #expect(FileManager.default.fileExists(atPath: setup.appendingPathComponent("boot1.bin").path))
    }

    @Test func failedFinalPackageVerificationCannotLeaveACompletedRecoveryPackage() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let setup = try snapshot(root, hwid: String(repeating: "8", count: 32)) else { return }
        let material = try SNESRecoveryMaterial.load(setup: setup)
        let store = try RecoveryBootSnapshotStore(root: root)
        await #expect(throws: (any Error).self) {
            try await store.saveSNESRecoveryMaterial(material, verify: { _ in
                throw RecoveryProbeError.refused("Verification failed")
            })
        }
        let packages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("SNES-Recovery-Material-") }
        #expect(packages.count == 1)
        #expect(packages.allSatisfy { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) })
        #expect(try SNESRecoveryMaterial.load(setup: setup).expectedHWID == String(repeating: "8", count: 32))
    }

    @Test func recoveryPreparationCannotFallThroughToHardware() async throws {
        for args in [["--prepare-snes-recovery"], ["--prepare-snes-recovery", "relative", "/Backups"],
                     ["--prepare-snes-recovery", "/missing", "/Backups", "extra"],
                     ["--prepare-snes-recovery", "/missing", "/Backups"]] {
            await #expect(throws: (any Error).self) {
                try await SNESOfflineBuildDiagnostic.dispatch(args, online: { Issue.record("Recovery preparation reached hardware") })
            }
        }
    }
    @Test func successfulOfflineRecoveryPreparationCreatesCheckedPackage() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let setup = try snapshot(root, hwid: String(repeating: "4", count: 32)) else { return }
        try await SNESOfflineBuildDiagnostic.dispatch(["--prepare-snes-recovery", setup.path, root.path],
            online: { Issue.record("Recovery preparation reached hardware") })
        let packages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("SNES-Recovery-Material-") }
        #expect(packages.count == 1)
        if let package = packages.first { #expect(try SNESRecoveryMaterial.loadPackage(directory: package).expectedHWID == String(repeating: "4", count: 32)) }
    }
}


extension SNESRecoveryMaterialTests {
    func rewriteReceipt(_ package: URL, edit: (inout [String: Any]) throws -> Void) throws {
        let receiptURL = package.appendingPathComponent("recovery-review.json")
        var receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        try edit(&receipt)
        let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try bytes.write(to: receiptURL)
        let manifestURL = package.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var hashes = try #require(manifest["recoveryFiles"] as? [String: String])
        hashes["recovery-review.json"] = BackupManifest.digest(bytes)
        manifest["recoveryFiles"] = hashes
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    }
    @Test func earlierPresentationRemainsReadableButChangedSafetySemanticsAreRefused() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let setup = try snapshot(root, hwid: String(repeating: "5", count: 32)) else { return }
        let material = try SNESRecoveryMaterial.load(setup: setup)
        let package = try await RecoveryBootSnapshotStore(root: root).saveSNESRecoveryMaterial(material)
        try rewriteReceipt(package) { receipt in
            var choices = try #require(receipt["choices"] as? [[String: Any]])
            choices[0]["title"] = "Original games"
            choices[0]["explanation"] = "Earlier app wording."
            receipt["choices"] = choices
        }
        #expect(throws: Never.self) { try SNESRecoveryMaterial.loadPackage(directory: package) }
        let acceptedReceipt = try Data(contentsOf: package.appendingPathComponent("recovery-review.json"))
        let acceptedManifest = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        for key in ["geometryWriteAuthorized", "firmwareRestoreEligible"] {
            try rewriteReceipt(package) { $0[key] = true }
            #expect(throws: (any Error).self) { try SNESRecoveryMaterial.loadPackage(directory: package) }
            try acceptedReceipt.write(to: package.appendingPathComponent("recovery-review.json"))
            try acceptedManifest.write(to: package.appendingPathComponent("manifest.json"))
        }
        try rewriteReceipt(package) { receipt in
            var choices = try #require(receipt["choices"] as? [[String: Any]])
            var effects = try #require(choices[0]["effects"] as? [String: Any])
            effects["erasesSavesAndSettings"] = true; choices[0]["effects"] = effects; receipt["choices"] = choices
        }
        #expect(throws: (any Error).self) { try SNESRecoveryMaterial.loadPackage(directory: package) }
    }
    @Test func missingExtraAndHardlinkedMembersAreRefused() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let setup = try snapshot(root, hwid: String(repeating: "6", count: 32)) else { return }
        let material = try SNESRecoveryMaterial.load(setup: setup)
        let package = try await RecoveryBootSnapshotStore(root: root).saveSNESRecoveryMaterial(material)
        let member = package.appendingPathComponent("boot1.bin"), bytes = try Data(contentsOf: member)
        try FileManager.default.removeItem(at: member)
        #expect(throws: (any Error).self) { try SNESRecoveryMaterial.loadPackage(directory: package) }
        try bytes.write(to: member); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: member.path)
        let extra = package.appendingPathComponent("unexpected.txt")
        try Data().write(to: extra)
        #expect(throws: (any Error).self) { try SNESRecoveryMaterial.loadPackage(directory: package) }
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.linkItem(at: member, to: root.appendingPathComponent("hardlink"))
        #expect(throws: (any Error).self) { try SNESRecoveryMaterial.loadPackage(directory: package) }
        await #expect(throws: (any Error).self) {
            try await SNESOfflineBuildDiagnostic.dispatch(["--prepare-snes-recovery", package.path, root.path],
                online: { Issue.record("Invalid setup reached hardware") })
        }
    }
}
