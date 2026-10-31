import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESOfflineImageBuildTests {
    @Test func strictOfflineOptionsAndFailureNeverReachHardwareBranch() async throws {
        #expect(try SNESOfflineBuildOptions.parseIfPresent(["--inspect-snes-image", "/snapshot"]) == .inspect("/snapshot"))
        #expect(try SNESOfflineBuildOptions.parseIfPresent(["--inspect"]) == nil)
        for args in [["--inspect-snes-image"], ["--inspect-snes-image", "relative"],
                     ["--build-snes-image", "/a", "/b"], ["--build-snes-image", "/a", "/b", "/c", "extra"],
                     ["--inspect-snes-image", "/missing\0path"]] {
            await #expect(throws: (any Error).self) {
                try await SNESOfflineBuildDiagnostic.dispatch(args, online: { Issue.record("Invalid offline command reached hardware") })
            }
        }
        await #expect(throws: (any Error).self) {
            try await SNESOfflineBuildDiagnostic.dispatch(["--inspect-snes-image", "/missing-snapshot"],
                online: { Issue.record("Offline load failure reached hardware") })
        }
    }
    @Test func fakeOrIncompleteSourcesAreRefused() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("SNES-US-Setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try SNESOfflineSource.load(snapshot: snapshot) }
        try snapshotFixture().write(to: snapshot.appendingPathComponent("active-boot2.img"))
        #expect(throws: (any Error).self) { try SNESOfflineSource.load(snapshot: snapshot) }
    }
    @Test func privateRealStockBuildAndExportWhenProvided() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SWIFTHAKCHI_SNES_SETUP"], let kernelPath = env["SWIFTHAKCHI_SNES_KERNEL"] else { return }
        let source = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: path))
        let before = BackupManifest.digest(source.stock)
        let inspected = try LegacyBootImageBuilder.inspect(source.stock)
        #expect(inspected.archive.entries.count == 18)
        let originalArchive = try LegacyAndroidBootImage(data: source.stock)
        #expect(BackupManifest.digest(try LZOPArchive.decode(source.stock.subdata(in: originalArchive.ramdiskRange))) == "ca1edd2b0a57c43a3ed2e3e03cdebadc1f1d68906b966b317838ca89d3fdd366")
        let kernel = try Data(contentsOf: URL(fileURLWithPath: kernelPath))
        let build = try SNESOfflineImageBuild.make(source: source, kernel: kernel)
        #expect(build.image == (try SNESOfflineImageBuild.make(source: source, kernel: kernel).image))
        #expect(try LegacyBootImageBuilder.inspect(build.image).archive == inspected.archive)
        #expect(BackupManifest.digest(source.stock) == before)
        #expect(throws: (any Error).self) { try SNESOfflineImageBuild.make(source: source, kernel: Data([1])) }
        #expect(throws: (any Error).self) { try SNESOfflineImageBuild.make(source: source, kernel: kernel, replacements: ["key-file": Data(count: 32)]) }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = try await RecoveryBootSnapshotStore(root: root).saveSNESBuild(build)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["bootEligible"] as? Bool == false)
        #expect(manifest["firmwareRestoreEligible"] as? Bool == false)
        #expect(manifest["complete"] as? Bool == true)
        #expect(try Data(contentsOf: output.appendingPathComponent("candidate.img")) == build.image)
        for file in [output, output.appendingPathComponent("candidate.img"), output.appendingPathComponent("manifest.json")] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == (file == output ? 0o700 : 0o600))
        }
        let badStore = try RecoveryBootSnapshotStore(root: root, synchronize: { _ in -1 })
        await #expect(throws: (any Error).self) { try await badStore.saveSNESBuild(build) }
        // Successful dispatch must also bypass the online/payload branch.
        try await SNESOfflineBuildDiagnostic.dispatch(["--inspect-snes-image", path], online: { Issue.record("Offline inspect reached hardware") })
        try await SNESOfflineBuildDiagnostic.dispatch(["--build-snes-image", path, kernelPath, root.path], online: { Issue.record("Offline build reached hardware") })
        // Alter copies only: the source snapshot and stock image are never written.
        let copy = root.appendingPathComponent("SNES-US-Setup-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        let copiedSource = try SNESOfflineSource.load(snapshot: copy)
        let copiedBuild = try SNESOfflineImageBuild.make(source: copiedSource, kernel: kernel)
        let manifestPath = copy.appendingPathComponent("manifest.json")
        let originalManifest = try Data(contentsOf: manifestPath)
        for field in ["complete", "console", "firmwareRestoreEligible"] {
            var altered = try #require(JSONSerialization.jsonObject(with: originalManifest) as? [String: Any])
            altered[field] = field == "complete" ? false : (field == "console" ? "nes" : true)
            try JSONSerialization.data(withJSONObject: altered).write(to: manifestPath)
            #expect(throws: (any Error).self) { try SNESOfflineSource.load(snapshot: copy) }
        }
        try originalManifest.write(to: manifestPath)
        let headerPath = copy.appendingPathComponent("data-header.bin")
        var header = try Data(contentsOf: headerPath); header[0] ^= 1
        try header.write(to: headerPath)
        #expect(throws: (any Error).self) { try SNESOfflineSource.load(snapshot: copy) }
        await #expect(throws: (any Error).self) { try await RecoveryBootSnapshotStore(root: root).saveSNESBuild(copiedBuild) }
        #expect(BackupManifest.digest(try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("active-boot2.img"))) == before)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { try SNESOfflineSource.load(snapshot: link) }
        #expect(throws: (any Error).self) { try RecoveryBootSnapshotStore(root: link) }
    }
}
