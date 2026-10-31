import Foundation
import Testing
@testable import SwiftHakchi

extension StartupTrialSessionFake:SNESInstalledStartupIO {}
@Suite(.serialized)
struct SNESInstalledStartupCheckTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["none","early","inventory","connect","report","second","attachment","cancel"])
    func normalStartupRequiresTwoFreshBoundReportsWithoutBooting(_ fault:String) async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        if fault != "early" {try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified()}
        let io=StartupTrialSessionFake(expected:try .checked(m.trial),fault:fault,booted:true)
        do {
            let result=try await SNESInstalledStartupCheck().run(journal:j,guard:g,io:io)
            #expect(fault=="none")
            #expect(Set(result.challenges).count==2 && result.reports.count==2)
            #expect(try await j.phase() == .startupVerified)
            let raw=try result.export();#expect(raw.contains("normal-startup") && !raw.isEmpty)
            try await j.acceptMenu()
        } catch {#expect(fault != "none");#expect(try await j.phase()==(fault=="early" ? .prepared:.readbackVerified))}
        #expect(await io.events.contains("boot")==false)
        #expect(await io.events.filter{$0=="close"}.count==1)
        try await j.close()
    }
}
