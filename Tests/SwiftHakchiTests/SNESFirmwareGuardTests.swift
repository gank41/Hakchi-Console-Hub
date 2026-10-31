import Foundation
import Testing
@testable import SwiftHakchi

actor SNESFirmwareGuardFixtureCache {
    static let shared=SNESFirmwareGuardFixtureCache()
    private var saved:SNESFirmwareGuard?
    func value() async throws->SNESFirmwareGuard {
        if let saved {return saved};let material=try await SNESFirmwareFixtureCache.shared.value()
        if let saved {return saved}
        let guardValue=try SNESFirmwareGuard.prepare(material);saved=guardValue;return guardValue
    }
}
struct SNESFirmwareGuardTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func bindsOperationAndDetectsHelperChangeAcrossSuspension() async throws {
        let original=try await SNESFirmwareFixtureCache.shared.value(),originalGuard=try await SNESFirmwareGuardFixtureCache.shared.value()
        try originalGuard.require(original)
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("writer");try original.writer.bytes.write(to:helper)
        let p=original.paths,paths=SNESFirmwarePaths(candidate:p.candidate,preflight:p.preflight,started:p.started,played:p.played,original:p.original,reader:p.reader,writer:helper.path)
        let pins=try PinnedFELInputs.load(),material=try SNESFirmwareMaterial.install(paths:paths,recovery:.init(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage))
        #expect(throws:(any Error).self){try originalGuard.require(material)}
        let guardValue=try SNESFirmwareGuard.prepare(material);try guardValue.require(material)
        await Task.yield();try Data([1]).write(to:helper)
        #expect(throws:(any Error).self){try guardValue.validate()}
        try originalGuard.validate()
    }
}
