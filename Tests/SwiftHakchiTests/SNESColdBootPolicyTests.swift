import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESColdBootPolicyTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func refusesUnsupportedXZBeforeBootOrInstallation() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value()
        let stock=m.source.stock,decoded=try LegacyBootImageBuilder.inspect(stock)
        try SNESColdBootPolicy.require(boot1:m.source.boot1,image:stock)
        let unsupported=try LegacyBootImageBuilder.build(source:stock,kernel:decoded.kernel,archive:decoded.archive,ramdiskEncoding:.xz)
        #expect(throws:(any Error).self) {try SNESColdBootPolicy.require(boot1:m.source.boot1,image:unsupported)}
        let wrongKernel=try LegacyBootImageBuilder.build(source:stock,kernel:Data([1,2,3]),archive:decoded.archive)
        #expect(throws:(any Error).self) {try SNESColdBootPolicy.require(boot1:m.source.boot1,image:wrongKernel)}
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func rejectsUnloadedImageBytesAndUnauditedBootloader() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),boot1=m.source.boot1
        for size in [1,2_736_128,4_194_304] {try SNESColdBootPolicy.require(boot1:boot1,imageByteCount:size)}
        for size in [-1,0,4_194_305,6_285_312] {
            #expect(throws:(any Error).self) {try SNESColdBootPolicy.require(boot1:boot1,imageByteCount:size)}
        }
        var changed=boot1;changed[100]^=1
        #expect(throws:(any Error).self) {try SNESColdBootPolicy.require(boot1:changed,imageByteCount:2_736_128)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func oldOversizedInstallRefusesBeforeNativeConnectionOrUpload() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value()
        let base=SNESFirmwareFakeIO(material:m,fault:"none"),shell=SNESFirmwareShellFake(material:m,fault:"none")
        #expect(throws:(any Error).self) {_=try NativeSNESFirmwareIO(material:m,guard:g,base:base,shell:shell)}
        #expect(await base.base.events.isEmpty)
        let uploads=await shell.uploads,writes=await shell.writeCalls
        #expect(uploads==0 && writes==0)
    }
}
