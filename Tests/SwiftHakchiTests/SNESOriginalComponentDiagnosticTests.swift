import Foundation
import Darwin
import Testing
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESOriginalComponentDiagnosticTests {
    @Test func unconfirmedMarkerCleanupReachesCallerWithoutBeingReplaced() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        guard let source=try await originalComponentSourceFixture(root:root) else { return }
        let io=OriginalComponentFakeIO(source:source)
        do {
            _=try await SNESOriginalComponentDiagnostic.runIfPresent([
                "--capture-snes-original-components",source.material.setup.directoryURL.path,
                source.material.source.directoryURL.path,source.material.directoryURL.path,root.path],
                checkHost:{},makeIO:{_ in io},makeStore:{ url in
                    try RecoveryBootSnapshotStore(root:url,synchronize:{fd in
                        var info=stat()
                        if fstatat(fd,"manifest.json",&info,AT_SYMLINK_NOFOLLOW)==0 { errno=EIO;return -1 }
                        return fsync(fd)
                    },removeManifest:{_,_ in errno=EACCES;return -1})
                })
            Issue.record("Uncertain cleanup was accepted")
        } catch let error as RecoverySnapshotCleanupError {
            #expect(error.directory.lastPathComponent.hasPrefix("SNES-Original-Components-"))
        } catch { Issue.record("Uncertain cleanup was replaced by another error") }
    }
    @Test func invalidOptionsRefuseBeforeUSBFactoryOrHostCheck() async throws {
        #expect(try await SNESOriginalComponentDiagnostic.runIfPresent(["--other"], makeIO: { _ in Issue.record("Unexpected IO"); fatalError() }) == nil)
        for args in [["--capture-snes-original-components"], ["--capture-snes-original-components", "relative", "/tmp", "/tmp", "/tmp"],
                     ["--capture-snes-original-components", "/missing", "/tmp", "/tmp", "/tmp"]] {
            await #expect(throws: (any Error).self) {
                _ = try await SNESOriginalComponentDiagnostic.runIfPresent(args,
                    checkHost: { Issue.record("Unexpected host check") }, makeIO: { _ in Issue.record("Unexpected IO"); fatalError() })
            }
        }
    }
    @Test func changedSourceDuringHostAwaitCannotCreateUSB() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await originalComponentSourceFixture(root: root) else { return }
        await #expect(throws: (any Error).self) {
            _ = try await SNESOriginalComponentDiagnostic.runIfPresent([
                "--capture-snes-original-components", source.material.setup.directoryURL.path,
                source.material.source.directoryURL.path, source.material.directoryURL.path, root.path],
                checkHost: { try Data([1]).write(to: source.material.directoryURL.appendingPathComponent("support.frame")) },
                makeIO: { _ in Issue.record("Changed source reached USB"); fatalError() })
        }
    }
    @Test(arguments: ["none", "transport", "empty", "final-observation"])
    func completedAndFailedExportsArePrivateAndCannotBecomeInstallPermission(fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await originalComponentSourceFixture(root: root) else { return }
        let io = OriginalComponentFakeIO(source: source, fault: fault)
        let args = ["--capture-snes-original-components", source.material.setup.directoryURL.path,
            source.material.source.directoryURL.path, source.material.directoryURL.path, root.path]
        do {
            let output = try await SNESOriginalComponentDiagnostic.runIfPresent(args, checkHost: {}, makeIO: { _ in io })
            #expect(output != nil && fault == "none")
        } catch { #expect(fault != "none") }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("SNES-Original-Components-") }
        let folder = try #require(folders.first)
        #expect(folders.count == 1)
        let url = folder.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(manifest["complete"] as? Bool == (fault == "none"))
        #expect(manifest["firmwareWritten"] as? Bool == false && manifest["firmwareRestoreEligible"] as? Bool == false)
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        }
        if fault == "none" {
            manifest["firmwareRestoreEligible"] = true
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
            #expect(throws: (any Error).self) { _ = try SNESOriginalComponentMaterial.load(source: source, directory: folder) }
        }
        #expect(await io.base.events.filter { $0 == "disconnect" }.count == 1)
    }
}
