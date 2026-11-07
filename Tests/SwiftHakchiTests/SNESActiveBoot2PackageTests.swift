import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor SNESPhysicalSnapshotFixtureCache {
    static let shared=SNESPhysicalSnapshotFixtureCache()
    private var saved:SNESActiveBoot2Snapshot?
    func snapshot() async throws->SNESActiveBoot2Snapshot {
        if let saved {return saved}
        let source=try #require(try snesPreparationFixture()),path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"])
        let helper=try SNESBoundedReadHelper.load(URL(fileURLWithPath:path)),pins=try PinnedFELInputs.load()
        let value=try await SNESActiveBoot2SnapshotService(wait:{}).capture(source:source,inputs:.init(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage),helper:helper,io:SNESActiveBoot2FakeIO(source:source,fault:"none"))
        saved=value;return value
    }
}
@Suite(.serialized)
struct SNESActiveBoot2PackageTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"] != nil))
    func returnsExactReceiptAndRemovesCompletionWhenFinalCheckChangesFiles() async throws {
        let snapshot = try await SNESPhysicalSnapshotFixtureCache.shared.snapshot(), root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        let receipt = try await store.saveSNESActiveBoot2WithReceipt(snapshot)
        #expect(receipt.kind == .activeBoot2)
        let loaded = try SNESActiveBoot2Package.load(directory: receipt.directory, source: snapshot.source)
        #expect(loaded.manifestSHA256 == receipt.manifestSHA256 && loaded.active == snapshot.active)
        await #expect(throws: (any Error).self) {
            try await store.saveSNESActiveBoot2WithReceipt(snapshot, verify: { directory in
                try Data(count: 24).write(to: directory.appendingPathComponent("geometry.bin"))
            })
        }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let incomplete = try #require(folders.first { $0 != receipt.directory })
        #expect(!FileManager.default.fileExists(atPath: incomplete.appendingPathComponent("manifest.json").path))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"] != nil),arguments:["none","flag","geometry","active","extra","unknown","challenges","source","range"])
    func reopensOnlyCompleteExactSourceBoundPreimage(_ fault:String) async throws {
        let snapshot=try await SNESPhysicalSnapshotFixtureCache.shared.snapshot(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let store=try RecoveryBootSnapshotStore(root:root),directory=try await store.saveSNESActiveBoot2(snapshot)
        switch fault {
        case "flag":let f=directory.appendingPathComponent("manifest.json");var m=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:f)) as? [String:Any]);m["firmwareInstallEligible"]=true;try JSONSerialization.data(withJSONObject:m).write(to:f)
        case "unknown","challenges","source","range":
            let f=directory.appendingPathComponent("manifest.json");var m=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:f)) as? [String:Any])
            switch fault {
            case "unknown":m["unexpected"]=true
            case "challenges":m["challenges"]=Array(repeating:UUID().uuidString,count:4)
            case "source":m["sourceManifestSHA256"]=String(repeating:"0",count:64)
            default:m["offsetBytes"]=0
            }
            try JSONSerialization.data(withJSONObject:m).write(to:f)
        case "geometry":try Data(count:24).write(to:directory.appendingPathComponent("geometry.bin"))
        case "active":let f=directory.appendingPathComponent("active-range.bin");var d=try Data(contentsOf:f);d[0]^=1;try d.write(to:f)
        case "extra":try Data([1]).write(to:directory.appendingPathComponent("extra"))
        default:break
        }
        if fault=="none" {
            let package=try SNESActiveBoot2Package.load(directory:directory,source:snapshot.source)
            #expect(package.byteCount==7340032 && package.sha256==BackupManifest.digest(snapshot.active))
            #expect(package.active==snapshot.active)
        } else {#expect(throws:(any Error).self) {try SNESActiveBoot2Package.load(directory:directory,source:snapshot.source)}}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"] != nil))
    func savesEmptyInertFailureWithoutRereadingFailedSource() async throws {
        let snapshot=try await SNESPhysicalSnapshotFixtureCache.shared.snapshot(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let store=try RecoveryBootSnapshotStore(root:root),path=try await store.saveSNESActiveBoot2Failure(.init(binding:snapshot.source.source.runtimeBinding,stage:"test",reason:"expected",partial:Data()))
        #expect(try FileManager.default.contentsOfDirectory(atPath:path.path)==["manifest.json"])
        let m=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:path.appendingPathComponent("manifest.json"))) as? [String:Any])
        #expect(m["complete"] as? Bool==false && m["firmwareWritten"] as? Bool==false && m["reason"] as? String=="expected")
    }
}
