import Foundation
import Testing
import Darwin
import os
@testable import SwiftHakchi
import SwiftHakchiCore

private func capturedReport() throws -> RecoveryRAMProbeReport {
    .init(before:probeFEL(), after:probeRNDIS(), observation:try RecoveryProbePolicy.observation(probeObservation()),
          bootSnapshot:try RecoveryBootSnapshot(active:.image(snapshotFixture()),backup:.unavailable))
}
struct RecoveryBootSnapshotStoreTests {
    @Test func exportPreservesPrivateBytesAndWritesVerifiedManifestLast() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let store = try RecoveryBootSnapshotStore(root:root), report = try capturedReport()
        let first = try await store.save(report), second = try await store.save(report)
        #expect(first != second)
        #expect(try Data(contentsOf:first.appendingPathComponent("active-boot2.img")) == snapshotFixture())
        #expect(FileManager.default.fileExists(atPath:first.appendingPathComponent("backup-boot2.img").path) == false)
        let raw = try Data(contentsOf:first.appendingPathComponent("manifest.json"))
        let json = try #require(JSONSerialization.jsonObject(with:raw) as? [String:Any])
        #expect(json["complete"] as? Bool == true)
        #expect(json["firmwareRestoreEligible"] as? Bool == false)
        let active = try #require((json["probe"] as? [String:Any])?["bootSnapshot"] as? [String:Any])
        #expect((active["active"] as? [String:Any])?["byteCount"] as? Int == 6144)
        #expect((active["backup"] as? [String:Any])?["status"] as? String == "unavailable")
        for path in [first, first.appendingPathComponent("active-boot2.img"), first.appendingPathComponent("manifest.json")] {
            let attributes = try FileManager.default.attributesOfItem(atPath:path.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == (path == first ? 0o700 : 0o600))
        }
    }
    @Test func destinationMustExistAndHaveNoSymbolicPathComponents() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let link = root.appendingPathComponent("link"), file = root.appendingPathComponent("file")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        try Data([1]).write(to:file)
        for invalid in [root.appendingPathComponent("missing"),link,file] {
            #expect(throws:(any Error).self) { try RecoveryBootSnapshotStore(root:invalid) }
        }
        #expect(try Data(contentsOf:file) == Data([1]))
    }
    @Test func missingCaptureAndMovedRootNeverCreateCompleteExport() async throws {
        let root = try testDirectory(), moved = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:moved) }
        let store = try RecoveryBootSnapshotStore(root:root)
        let report = RecoveryRAMProbeReport(before:probeFEL(),after:probeRNDIS(),observation:try RecoveryProbePolicy.observation(probeObservation()),bootSnapshot:nil)
        await #expect(throws:(any Error).self) { try await store.save(report) }
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        try FileManager.default.moveItem(at:root,to:moved)
        await #expect(throws:(any Error).self) { try await store.save(capturedReport()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath:moved.path).isEmpty)
    }
    @Test(arguments:[1,6]) func replacedChildNameNeverPublishesACompletionManifest(atBarrier:Int) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let moved = root.appendingPathComponent("moved"), counter = OSAllocatedUnfairLock(initialState:0)
        let store = try RecoveryBootSnapshotStore(root:root,synchronize:{ fd in
            let call = counter.withLock { $0 += 1; return $0 }
            if call == atBarrier {
                do {
                    let name = try #require(FileManager.default.contentsOfDirectory(atPath:root.path).first(where:{$0.hasPrefix("Boot2Snapshot-")}))
                    let child = root.appendingPathComponent(name)
                    try FileManager.default.moveItem(at:child,to:moved)
                    try Data("replacement".utf8).write(to:child)
                } catch { Issue.record("Could not simulate destination replacement: \(error)") }
            }
            return Darwin.fsync(fd)
        })
        await #expect(throws:(any Error).self) { try await store.save(capturedReport()) }
        #expect(FileManager.default.fileExists(atPath:moved.appendingPathComponent("manifest.json").path) == false)
        let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        let replacement = try #require(files.first(where:{$0.lastPathComponent.hasPrefix("Boot2Snapshot-")}))
        #expect(try Data(contentsOf:replacement) == Data("replacement".utf8))
    }
    @Test func cancellationDuringFinalDurabilityBarrierRemovesCompletionManifest() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let counter = OSAllocatedUnfairLock(initialState:0)
        let store = try RecoveryBootSnapshotStore(root:root,synchronize:{ fd in
            let result = Darwin.fsync(fd)
            if counter.withLock({ $0 += 1; return $0 }) == 6 { withUnsafeCurrentTask { $0?.cancel() } }
            return result
        })
        let task = Task { try await store.save(capturedReport()) }
        await #expect(throws:CancellationError.self) { try await task.value }
        let children = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        #expect(children.count == 1)
        #expect(FileManager.default.fileExists(atPath:children[0].appendingPathComponent("manifest.json").path) == false)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func recoveredStockIsRecognizedWithoutEmbeddingItsBytes() async throws {
        let root = URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"]))
        let readiness = await RecoveryPreflightService().inspect(backups:root)
        let path = try #require(readiness.kernel.path)
        let stock = try RecoveryMaterialReader.readFile(at:path,maximumBytes:16*1024*1024)
        let capture = try RecoveryBootSnapshot(active:.image(snapshotFixture()),backup:.image(stock))
        #expect(capture.activeIsKnownStock == false && capture.backupIsKnownStock)
        #expect(capture.backup == stock)
        let json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(capture)) as? [String:Any])
        #expect((json["backup"] as? [String:Any])?["sha256"] as? String == "83efe33290867ec6e6b5c5a18e21f8cfe6f97b079c2e3c5039c628e729755888")
    }
    @Test func snapshotCLIRejectsInvalidDestinationBeforeNativeIO() async throws {
        #expect(try RecoveryDiagnosticOptions.parse(["--snapshot-boot2","/missing"]) == .snapshot("/missing"))
        for args in [["--snapshot-boot2"],["--snapshot-boot2", "relative"],["--snapshot-boot2","/tmp","--boot-recovery"]] {
            #expect(throws:(any Error).self) { try RecoveryDiagnosticOptions.parse(args) }
        }
        let raw = try PinnedFELInputs.load()
        await #expect(throws:(any Error).self) {
            try await RecoveryDiagnosticRunner.run(mode:.snapshot("/private/tmp/nes-missing-" + UUID().uuidString),
                inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),makeIO:{
                    Issue.record("Invalid destination created native I/O")
                    return NativeRecoveryProbeIO()
                })
        }
    }
}
