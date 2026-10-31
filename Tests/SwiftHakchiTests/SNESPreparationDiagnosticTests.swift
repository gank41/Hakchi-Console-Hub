import Foundation
import Testing
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESPreparationDiagnosticTests {
    @Test(arguments: [-5, -7, -43, -66])
    func failedTransportPreservesBoundedCaptureEvidence(code: Int) async throws {
        do {
            _ = try await SNESStartupReceipt.capture {
                BoundedSSHExecution(stdout: Data("partial".utf8), stderr: Data("reading-text\n".utf8), exitCode: 0, transportCode: code)
            }
            Issue.record("Incomplete transport was accepted")
        } catch let failure as SNESStartupTransportFailure {
            #expect(failure.frame == Data("partial".utf8))
            #expect(failure.stageLog == Data("reading-text\n".utf8))
        }
    }
    @Test func invalidModesAndSourcesNeverConstructIO() async throws {
        let unrelated = try await SNESPreparationDiagnostic.runIfPresent(["--another-mode"], makeIO: { _ in Issue.record("Unexpected I/O"); fatalError() })
        #expect(unrelated == nil)
        for args in [["--prepare-snes-recovery"], ["--prepare-snes-recovery", "relative", "/tmp"],
                     ["--prepare-snes-recovery", "/missing", "/tmp"]] {
            await #expect(throws: (any Error).self) {
                try await SNESPreparationDiagnostic.runIfPresent(args,
                    checkHost: { Issue.record("Bad material reached host check") },
                    makeIO: { _ in Issue.record("Bad material reached I/O construction"); fatalError() })
            }
        }
    }
    @Test(arguments: ["none", "startup", "changed-startup", "transport-first", "transport-second", "transport-empty"])
    func diagnosticExportsOnlyCheckedCompletionOrPrivateFailure(fault: String) async throws {
        guard let source = try snesPreparationFixture() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let io = SNESPreparationFakeIO(source: source, fault: fault)
        let args = ["--prepare-snes-recovery", source.source.directoryURL.path, root.path]
        do {
            let text = try await SNESPreparationDiagnostic.runIfPresent(args, checkHost: {}, makeIO: { _ in io })
            #expect(fault == "none")
            let output = try #require(text)
            let parsed = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            #expect(parsed["firmwareWritten"] as? Bool == false)
        } catch { #expect(fault != "none") }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(folders.count == 1)
        let folder = try #require(folders.first)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["complete"] as? Bool == (fault == "none"))
        #expect(manifest["firmwareRestoreEligible"] as? Bool == false)
        #expect(manifest["firmwareWritten"] as? Bool == false)
        if fault.hasPrefix("transport-") {
            let envelope = try Data(contentsOf: folder.appendingPathComponent("rejected.frame"))
            let newline = try #require(envelope.firstIndex(of: 10))
            #expect(Data(envelope[(newline+1)...]) == (fault == "transport-empty" ? Data() : Data("partial".utf8)))
            #expect(await io.events.filter { $0 == "startup" }.count == (fault == "transport-second" ? 2 : 1))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(await io.events.filter { $0 == "disconnect" }.count == 1)
    }
}
