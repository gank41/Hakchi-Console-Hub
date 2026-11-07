import Foundation
import Testing
@testable import SwiftHakchiCore

struct SNESRAMMenuSignalTrialTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_MENU_SIGNAL_OWNER"] != nil, "Requires private local trial files"))
    func imagePinsSignalOwnerAndRejectsChanges() throws {
        let e=ProcessInfo.processInfo.environment
        let source=try Data(contentsOf:URL(fileURLWithPath:try #require(e["HC_MENU_SOURCE"])))
        let root=URL(fileURLWithPath:try #require(e["HC_MENU_PAYLOAD"]),isDirectory:true)
        let names=["retroarch","snes9x2010_libretro.so","alien3.smc","retroarch.cfg","trial-start","trial-owner","autoconfig/Nintendo Clovercon - controller1.cfg"]
        let payload=try Dictionary(uniqueKeysWithValues:names.map { ($0,try Data(contentsOf:root.appendingPathComponent($0))) })
        let report=try Data(contentsOf:URL(fileURLWithPath:try #require(e["HC_MENU_REPORT"])))
        let artwork=try Data(contentsOf:URL(fileURLWithPath:try #require(e["HC_MENU_ART"])))
        let old=try Data(contentsOf:URL(fileURLWithPath:try #require(e["HC_MENU_OWNER"])))
        let signal=try Data(contentsOf:URL(fileURLWithPath:try #require(e["HC_MENU_SIGNAL_OWNER"])))
        let result=try SNESRAMMenuSignalTrialBuilder.build(source:source,payload:payload,report:report,artwork:artwork,resetOwner:old,signalOwner:signal)
        let image=try LegacyBootImageBuilder.inspect(result.image)
        let files=Dictionary(uniqueKeysWithValues:image.archive.entries.map { ($0.name,$0.data) })
        #expect(files["probe/compat/trial-menu-owner"]==signal)
        let start=try #require(files["probe/compat/trial-start"].flatMap {String(data:$0,encoding:.utf8)})
        #expect(start.contains(SNESRAMMenuSignalTrialBuilder.ownerSHA256))
        #expect(!start.contains(SNESRAMMenuResetTrialBuilder.ownerSHA256))
        #expect(throws:(any Error).self) {try SNESRAMMenuSignalTrialBuilder.build(source:source,payload:payload,report:report,artwork:artwork,resetOwner:old,signalOwner:Data([0]))}
    }
}
