import Foundation
import Testing
@testable import SwiftHakchi

actor SNESFirmwareShellFake:SNESFirmwareShell {
    let material:SNESFirmwareMaterial,fault:String
    var uploads=0,writeCalls=0,creates=0
    init(material:SNESFirmwareMaterial,fault:String){self.material=material;self.fault=fault}
    func executeBounded(_ command:String,stdoutLimit:Int,stderrLimit:Int,timeout:Int)->BoundedSSHExecution {
        let output:String
        if command.contains("SWIFTHAKCHI_SNES_FIRMWARE_CREATED_V1") {creates+=1;output=fault=="stage" ? "wrong\n":SNESFirmwareCommands.created(material.id)}
        else if command.contains("SWIFTHAKCHI_SNES_FIRMWARE_STAGED_V1") {output=SNESFirmwareCommands.staged(material)}
        else {let writing=command.contains("replace-active");if writing {writeCalls+=1};output=SNESFirmwareCommands.marker(material,writing:writing)+((fault=="extra" || (writing && fault=="write-extra")) ? "extra\n":"")}
        return .init(stdout:Data(output.utf8),stderr:Data(),exitCode:(fault=="exit" || (writeCalls>0 && fault=="write-exit")) ? 1:0,transportCode:(fault=="transport" || (writeCalls>0 && fault=="write-transport")) ? -43:0)
    }
    func uploadExclusive(data:Data,to remotePath:String,timeout:Int)throws {uploads+=1;if fault=="upload" {throw SNESRuntimeBinding.failure()}}
}
@Suite(.serialized)
struct NativeSNESFirmwareIOTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["none","stage","upload","transport","exit","extra","not-ready","write-extra","write-exit","write-transport"])
    func requiresCompleteStagePositiveReceiptAndOnePermit(_ fault:String) async throws {
        let installed=try await SNESFirmwareFixtureCache.shared.value(),installGuard=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        // Exercise the same native writer protocol using valid original-restoration material.
        // The historical oversized install is now deliberately refused at native construction.
        let parentPrepared=try SNESFirmwareJournal.prepare(material:installed,root:root,guard:installGuard)
        let parent=try SNESFirmwareJournal(operation:parentPrepared.operation,reviewSHA256:parentPrepared.reviewSHA256,material:installed,guard:installGuard)
        try await parent.preflightVerified();_=try await parent.beginWrite();try await parent.readbackVerified()
        let m=try SNESFirmwareMaterial.restore(installed:await parent.restorableInstall()),g=try SNESFirmwareGuard.prepare(m)
        try await parent.close()
        let prepared=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),j=try SNESFirmwareJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m,guard:g)
        try await j.preflightVerified()
        let base=SNESFirmwareFakeIO(material:m,fault:"none"),shell=SNESFirmwareShellFake(material:m,fault:fault),io=try NativeSNESFirmwareIO(material:m,guard:g,base:base,shell:shell)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let before=try #require(try await base.inventory().first);try await io.boot(inputs,expected:before)
        let after=try #require(try await base.inventory().first);try await io.connect(expected:after)
        if fault != "not-ready" {_=try await io.readPartitions();_=try await io.readDataSuperblock()}
        do {
            try await io.stage();try await io.verifyStaged()
            let permit=try await j.beginWrite()
            do {try await io.replace(permit);#expect(fault=="none")} catch {#expect(fault.hasPrefix("write-"))}
            #expect(fault=="none" || fault.hasPrefix("write-"))
            await #expect(throws:(any Error).self){try await io.replace(permit)}
            await #expect(throws:(any Error).self){try await io.stage()}
        } catch {
            #expect(fault != "none")
            if fault=="transport" {
                #expect(error is SNESFirmwareCommandFailure)
                if let failure=error as? SNESFirmwareCommandFailure {#expect(failure.transport == -43 && failure.exit == 0 && !failure.diagnostic.isEmpty)}
            }
        }
        #expect(await shell.writeCalls==((fault=="none" || fault.hasPrefix("write-")) ? 1:0))
        let uploads=await shell.uploads,creates=await shell.creates
        if fault=="none" {#expect(uploads==2 && creates==1)}
        if fault=="not-ready" {#expect(uploads==0 && creates==0)}
        await io.disconnect();try await j.close()
    }
}
