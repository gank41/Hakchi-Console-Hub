import Foundation
import Testing
@testable import SwiftHakchi

private actor BindingProbe: RecoveryProbeIO {
    var inventoryCount = 0
    var opened: [RecoveryProbeUSBDevice] = []
    var booted: [RecoveryProbeUSBDevice] = []
    let changeAfterObservation: Bool
    init(changeAfterObservation: Bool = false) { self.changeAfterObservation = changeAfterObservation }
    func inventory() -> [RecoveryProbeUSBDevice] {
        inventoryCount += 1
        if inventoryCount == 1 { return [probeFEL()] }
        return [probeRNDIS(registryID: changeAfterObservation && inventoryCount >= 3 ? 9003 : 9002)]
    }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) { booted.append(expected) }
    func connect(expected: RecoveryProbeUSBDevice) { opened.append(expected) }
    func observe() -> String { probeObservation() }
    func disconnect() {}
}
struct RecoveryUSBBindingTests {
    @Test func absentOrZeroRegistryIdentityCannotAuthorizeRecovery() throws {
        for unknown: UInt64? in [nil,0] {
            #expect(throws: RecoveryProbeError.self) { try RecoveryProbePolicy.before([probeFEL(registryID: unknown)]) }
            #expect(throws: RecoveryProbeError.self) { try RecoveryProbePolicy.after([probeRNDIS(registryID: unknown)], original: probeFEL()) }
            #expect(throws: RecoveryProbeError.self) { try probeFEL(registryID: unknown).nativeIdentity(for: .fel) }
        }
        #expect(throws: RecoveryProbeError.self) { try probeFEL(location: 0).nativeIdentity(for: .fel) }
    }
    @Test func samePortFELReplacementIsRejected() throws {
        #expect(throws: RecoveryProbeError.self) {
            try RecoveryProbePolicy.after([probeFEL(registryID: 9003)], original: probeFEL())
        }
    }
    @Test func stageMappingRequiresCompleteModeAndIdentity() throws {
        let native = try probeFEL().nativeIdentity(for: .fel)
        #expect(native.registry_entry_id == 9001 && native.location_id == 123)
        #expect(native.vendor_id == 0x1f3a && native.product_id == 0xefe8 && native.device_version == 0x2b3)
        #expect(native.device_class == 0 && native.require_empty_product)
        let network = try probeRNDIS().nativeIdentity(for: .rndis)
        #expect(network.registry_entry_id == 9002 && network.location_id == 123)
        #expect(network.device_class == 224 && network.require_empty_product == false)
        #expect(throws: RecoveryProbeError.self) { try probeRNDIS().nativeIdentity(for: .fel) }
        #expect(throws: RecoveryProbeError.self) { try probeFEL().nativeIdentity(for: .rndis) }
    }
    @Test func exactAcceptedAttachmentsReachEachStage() async throws {
        let raw = try PinnedFELInputs.load(), io = BindingProbe()
        _ = try await RecoveryRAMProbe(wait: {}).run(inputs: .init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),io:io)
        #expect(await io.booted == [probeFEL()])
        #expect(await io.opened == [probeRNDIS()])
    }
    @Test func RNDISReplacementBeforeOpenDoesNotConnect() async throws {
        let raw = try PinnedFELInputs.load(), io = BindingProbe(changeAfterObservation:true)
        await #expect(throws: RecoveryProbeError.self) {
            try await RecoveryRAMProbe(wait: {}).run(inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),io:io)
        }
        #expect(await io.opened.isEmpty)
    }
    @Test func unknownIdentityAndCancellationFailBeforeNativeIO() async throws {
        await #expect(throws: RecoveryProbeError.self) { try await IOKitFELSessionTransport(expected:probeFEL(registryID:nil)).open() }
        await #expect(throws: RecoveryProbeError.self) { try await SSHService().connect(expected:probeRNDIS(registryID:0)) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await IOKitFELSessionTransport(expected:probeFEL()).open()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let sshTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SSHService().connect(expected:probeRNDIS())
        }
        await #expect(throws: CancellationError.self) { try await sshTask.value }
    }
    @Test func malformedRegistryFieldsCannotBecomeValidFELObservation() throws {
        let base: [String:Any] = ["idVendor":0x1f3a,"idProduct":0xefe8,"bcdDevice":0x2b3,"bDeviceClass":0,"locationID":123]
        for key in ["bcdDevice","bDeviceClass","locationID"] {
            for invalid: Any in [true, 1.5, "0", -1] {
                var props=base;props[key]=invalid
                #expect(throws: RecoveryProbeError.self) { try RecoveryProbeUSBRegistry.device(from:props, registryEntryID:9001) }
            }
        }
        var product=base;product["USB Product Name"]=123
        #expect(throws: RecoveryProbeError.self) { try RecoveryProbeUSBRegistry.device(from:product,registryEntryID:9001) }
    }
}
