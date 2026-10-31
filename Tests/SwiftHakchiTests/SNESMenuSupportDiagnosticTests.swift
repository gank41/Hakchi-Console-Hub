import Foundation
import Testing
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESMenuSupportDiagnosticTests {
    @Test func invalidOptionsFailBeforeIOOrHostCheck() async throws {
        let unknown = try await SNESMenuSupportDiagnostic.runIfPresent(["--unknown"], makeIO: { _ in Issue.record("Unexpected IO"); fatalError() })
        #expect(unknown == nil)
        for args in [["--capture-snes-menu-support"], ["--capture-snes-menu-support", "relative", "/tmp", "/tmp"], ["--capture-snes-menu-support", "/missing", "/tmp", "/tmp"]] {
            await #expect(throws: (any Error).self) {
                _ = try await SNESMenuSupportDiagnostic.runIfPresent(args,
                    checkHost: { Issue.record("Unexpected host check") }, makeIO: { _ in Issue.record("Unexpected IO"); fatalError() })
            }
        }
    }
    @Test(arguments: ["none", "truncated", "transport", "second-transport", "empty", "changed"])
    func exportIsPrivateAndHonest(fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await menuSupportSourceFixture(root: root) else { return }
        let io = MenuSupportFakeIO(source: source, fault: fault)
        let args = ["--capture-snes-menu-support", source.preparation.source.source.directoryURL.path, source.directoryURL.path, root.path]
        do {
            _ = try await SNESMenuSupportDiagnostic.runIfPresent(args, checkHost: {}, makeIO: { _ in io })
            #expect(fault == "none")
        } catch { #expect(fault != "none") }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("SNES-Menu-Support-") }
        #expect(folders.count == 1)
        let folder = try #require(folders.first)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["complete"] as? Bool == (fault == "none"))
        if fault.hasPrefix("final-") {
            #expect(manifest["stage"] as? String == "validation")
            let envelope = try Data(contentsOf: folder.appendingPathComponent("rejected.frame"))
            let newline = try #require(envelope.firstIndex(of: 10))
            #expect(Data(envelope[(newline+1)...]) == menuSupportFixture())
        }
        #expect(manifest["firmwareWritten"] as? Bool == false)
        #expect(manifest["firmwareRestoreEligible"] as? Bool == false)
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        }
        if fault == "empty" {
            let frame = try Data(contentsOf: folder.appendingPathComponent("rejected.frame"))
            #expect(frame.last == 10)
        }
        #expect(await io.base.events.filter { $0 == "disconnect" }.count == 1)
    }
    @Test(arguments: ["final-observation", "final-source"])
    func finalValidationPreservesTheAlreadyCapturedFrame(fault: String) async throws {
        try await exportIsPrivateAndHonest(fault: fault)
    }
    @Test func hostAwaitSourceMutationNeverConstructsIO() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await menuSupportSourceFixture(root: root) else { return }
        await #expect(throws: (any Error).self) {
            _ = try await SNESMenuSupportDiagnostic.runIfPresent(["--capture-snes-menu-support", source.preparation.source.source.directoryURL.path, source.directoryURL.path, root.path],
                checkHost: { try Data([1]).write(to: source.directoryURL.appendingPathComponent("startup.frame")) },
                makeIO: { _ in Issue.record("Changed source reached IO"); fatalError() })
        }
    }
}
