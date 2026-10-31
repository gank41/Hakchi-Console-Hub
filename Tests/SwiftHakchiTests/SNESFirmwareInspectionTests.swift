import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

extension SNESFirmwareFakeIO {func setObserved(_ bytes:Data){active=bytes}}
@Suite(.serialized)
struct SNESFirmwareInspectionTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["preimage","target","mixed","early","identity","partitions","header","boot1","geometry","attachment","unstable"])
    func classifiesTwoReadsWithoutWritingOrClearingIntent(_ fault:String) async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        if fault != "early" {try await j.preflightVerified();_=try await j.beginWrite()}
        let io=SNESFirmwareFakeIO(material:m,fault:fault=="preimage" ? "none":fault),pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        var observed=m.preimage
        if fault=="target" {observed=m.target}
        if fault=="mixed" {observed[0]^=1}
        await io.setObserved(observed)
        do {
            let result=try await SNESFirmwareInspection(wait:{}).run(journal:j,guard:g,inputs:inputs,io:io)
            #expect(["preimage","target","mixed"].contains(fault))
            #expect(result.classification.rawValue==fault)
            #expect(result.observedSHA256==BackupManifest.digest(observed))
        } catch {#expect(!["preimage","target","mixed"].contains(fault))}
        let writes=await io.writes,stages=await io.stages;#expect(writes==0 && stages==0)
        #expect(try await j.phase()==(fault=="early" ? .prepared:.writeIntent))
        #expect(await io.base.events.filter{$0=="disconnect"}.count==1)
        try await j.close()
    }
}
