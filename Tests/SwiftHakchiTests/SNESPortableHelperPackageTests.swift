import Foundation
import Darwin
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESPortableHelperPackageTests {
    @Test func failedManifestRemovalIsReportedAsUncertainCleanup() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let store=try RecoveryBootSnapshotStore(root:root,removeManifest:{_,_ in errno=EACCES;return -1})
        do {
            _=try await store.saveSNESPortableHelpers(verify:{_ in throw RecoveryProbeError.refused("verification failed")})
            Issue.record("A failed verification was accepted")
        } catch let error as RecoverySnapshotCleanupError {
            #expect(error.directory.deletingLastPathComponent().standardizedFileURL.path==root.standardizedFileURL.path)
            #expect(FileManager.default.fileExists(atPath:error.directory.appendingPathComponent("manifest.json").path))
        } catch { Issue.record("The uncertain cleanup was not identified") }
    }
    @Test func portableFirmwareRequestUsesVerifiedSavedHelpersAndRejectsUnknownFields() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try await RecoveryBootSnapshotStore(root: root).saveSNESPortableHelpers()
        let request = SNESPortableFirmwareRequest(candidate: root.appendingPathComponent("candidate").path,
            preflight: root.appendingPathComponent("preflight").path, started: root.appendingPathComponent("started").path,
            played: root.appendingPathComponent("played").path, original: root.appendingPathComponent("original").path,
            helpers: directory.path)
        let data = try JSONEncoder().encode(request)
        let paths = try SNESPortableFirmwareRequest.resolve(data)
        #expect(paths.reader == directory.appendingPathComponent("reader").path)
        #expect(paths.writer == directory.appendingPathComponent("writer").path)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unexpected"] = true
        #expect(throws: (any Error).self) { try SNESPortableFirmwareRequest.resolve(JSONSerialization.data(withJSONObject: object)) }
        try Data([0]).write(to: directory.appendingPathComponent("reader"))
        #expect(throws: (any Error).self) { try SNESPortableFirmwareRequest.resolve(data) }
    }
    @Test func packageKeepsBothExactHelpersAndRejectsLaterChanges() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        let directory = try await store.saveSNESPortableHelpers()
        let package = try SNESPortableHelperPackage.load(directory: directory)
        #expect(package.reader.digest == SNESPortableHelpers.Kind.reader.sha256)
        #expect(package.writer.digest == SNESPortableHelpers.Kind.writer.sha256)
        #expect(package.reader.location.deletingLastPathComponent() == directory)
        #expect(package.writer.location.deletingLastPathComponent() == directory)
        try package.revalidate()
        var changed = package.writer.bytes; changed[changed.count - 1] ^= 1
        try changed.write(to: package.writer.location)
        #expect(throws: (any Error).self) { try package.revalidate() }
        #expect(throws: (any Error).self) { try SNESPortableHelperPackage.load(directory: directory) }
    }

    @Test func failedFinalVerificationCannotLeaveACompleteHelperPackage() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        await #expect(throws: (any Error).self) {
            try await store.saveSNESPortableHelpers(verify: { _ in throw RecoveryProbeError.refused("Test failure") })
        }
        let packages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("SNES-Setup-Helpers-") }
        #expect(packages.count == 1)
        #expect(packages.allSatisfy { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) })
    }

    @Test func firmwareInputsUseDurableHelperPathsAndRejectChangedPackages() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try await RecoveryBootSnapshotStore(root: root).saveSNESPortableHelpers()
        let package = try SNESPortableHelperPackage.load(directory: directory)
        let paths = try SNESFirmwarePaths.withHelpers(candidate: root.appendingPathComponent("candidate"),
            preflight: root.appendingPathComponent("preflight"), started: root.appendingPathComponent("started"),
            played: root.appendingPathComponent("played"), original: root.appendingPathComponent("original"), helpers: package)
        #expect(paths.reader == package.reader.location.path && paths.writer == package.writer.location.path)
        try Data([0]).write(to: package.reader.location)
        #expect(throws: (any Error).self) {
            try SNESFirmwarePaths.withHelpers(candidate: root.appendingPathComponent("candidate"),
                preflight: root.appendingPathComponent("preflight"), started: root.appendingPathComponent("started"),
                played: root.appendingPathComponent("played"), original: root.appendingPathComponent("original"), helpers: package)
        }
    }
}
