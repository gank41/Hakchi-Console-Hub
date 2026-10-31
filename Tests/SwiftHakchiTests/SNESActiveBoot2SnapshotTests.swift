import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func physicalGeometryFixture(page:UInt32=2048,perBlock:UInt32=64,blocks:UInt32=4096)->Data {
    Data("hakchi\0\0".utf8)+Data([UInt32(24),page,perBlock,blocks].flatMap {w in (0..<4).map {UInt8(truncatingIfNeeded:w >> ($0*8))}})
}
func physicalFrameFixture(_ bytes:Data,kind:SNESPhysicalFrame.Kind,challenge:UUID)->Data {
    let sha=BackupManifest.digest(bytes)
    return Data("\(kind.label) \(challenge.uuidString) \(bytes.count) \(sha)\n".utf8)+bytes+Data("\nSWIFTHAKCHI_SNES_PHYSICAL_END_V1 \(challenge.uuidString) \(sha)\n".utf8)
}
struct SNESActiveBoot2SnapshotTests {
    @Test func acceptsOnlyBoundedPhysicalGeometry()throws {
        _=try SNESPhysicalGeometry(physicalGeometryFixture())
        for raw in [Data(),physicalGeometryFixture().dropLast(),physicalGeometryFixture(page:0),physicalGeometryFixture(perBlock:0),physicalGeometryFixture(page:4096),physicalGeometryFixture(blocks:103),physicalGeometryFixture(page:.max,perBlock:.max)] {
            #expect(throws:(any Error).self) {try SNESPhysicalGeometry(Data(raw))}
        }
    }
    @Test func requiresExactChallengeLengthDigestAndCompletion()throws {
        let id=UUID(),data=physicalGeometryFixture(),frame=physicalFrameFixture(data,kind:.geometry,challenge:id)
        #expect(try SNESPhysicalFrame(frame,kind:.geometry,challenge:id).bytes==data)
        var modified=frame;modified[frame.firstIndex(of:10)!+1]^=1
        for bad in [Data(),Data(frame.dropLast()),frame+Data([0]),modified,physicalFrameFixture(data,kind:.geometry,challenge:UUID()),physicalFrameFixture(data+Data([0]),kind:.geometry,challenge:id)] {
            #expect(throws:(any Error).self) {try SNESPhysicalFrame(bad,kind:.geometry,challenge:id)}
        }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"] != nil))
    func loadsOnlyTheReviewedReadOnlyHelper()throws {
        let p=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"])
        let h=try SNESBoundedReadHelper.load(URL(fileURLWithPath:p))
        #expect(h.bytes.count==11928 && BackupManifest.digest(h.bytes)==SNESBoundedReadHelper.sha256)
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        var bad=h.bytes;bad[0]^=1;let f=root.appendingPathComponent("changed-helper");try bad.write(to:f)
        #expect(throws:(any Error).self) {try SNESBoundedReadHelper.load(f)}
        let link=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:URL(fileURLWithPath:p))
        #expect(throws:(any Error).self) {try SNESBoundedReadHelper.load(link)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_PHYSICAL_FRAMES"] != nil))
    func parsesFramesProducedByExecutedShell() throws {
        let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_PHYSICAL_FRAMES"])
        let files=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as? [String:String])
        let id=try #require(files["challenge"]),challenge=try #require(UUID(uuidString:id))
        for (name,kind) in [("geometry",SNESPhysicalFrame.Kind.geometry),("active",.active)] {
            let file=try #require(files[name]),frame=try SNESPhysicalFrame(Data(contentsOf:URL(fileURLWithPath:file)),kind:kind,challenge:challenge)
            #expect(frame.bytes.count==kind.count)
        }
    }

}
