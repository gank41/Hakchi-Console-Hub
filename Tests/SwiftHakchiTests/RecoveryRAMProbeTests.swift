import Foundation
import Testing
@testable import SwiftHakchi

func probeObservation() -> String {
    """
    SWIFTHAKCHI_RAM_PROBE_V1
    KERNEL=3.4.113.29-madmonkey
    CMDLINE=root=/dev/nandb decrypt ro hakchi-shell hakchi-memboot
    INIT_SHA=ede443827300aff46995b97bb73c221aba2a1e9a38c710160a2fa28fdaec45b0
    BASE_SHA=14a1dd7e3dae28339312fc379087c3e37119ce5684286e09a521f8cda318ae62
    BOARD=dp-nes
    NES_DIRECTORY=1
    HWID=0123456789abcdef0123456789abcdef
    MOUNTS_BEGIN
    rootfs / rootfs rw 0 0
    /dev/mapper/root-crypt /newroot squashfs ro,noatime 0 0
    MOUNTS_END
    END
    """ + "\n"
}
func probeFEL(location: UInt32 = 123, registryID: UInt64? = 9001) -> RecoveryProbeUSBDevice {
    .init(vendorID: 0x1f3a, productID: 0xefe8, deviceVersion: 0x02b3, deviceClass: 0, locationID: location, product: "", registryEntryID: registryID)
}
func probeRNDIS(location: UInt32 = 123, registryID: UInt64? = 9002) -> RecoveryProbeUSBDevice {
    .init(vendorID: 0x04e8, productID: 0x6863, deviceVersion: 0x0100, deviceClass: 224, locationID: location, product: "classic", registryEntryID: registryID)
}
private actor ProbeSpy: RecoveryProbeIO {
    enum Fault: Error { case injected }
    var devices: [[RecoveryProbeUSBDevice]]
    var events: [String] = []
    let fault: String?
    let observation: String
    init(devices: [[RecoveryProbeUSBDevice]] = [[probeFEL()], [probeRNDIS()]], fault: String? = nil,
         observation: String = probeObservation()) {
        self.devices = devices; self.fault = fault; self.observation = observation
    }
    func inventory() throws -> [RecoveryProbeUSBDevice] {
        events.append("inventory")
        if fault == "inventory" { throw Fault.injected }
        return devices.count > 1 ? devices.removeFirst() : devices[0]
    }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) throws { events.append("boot"); if fault == "boot" { throw Fault.injected } }
    func connect(expected: RecoveryProbeUSBDevice) throws { events.append("connect"); if fault == "connect" { throw Fault.injected } }
    func observe() throws -> String { events.append("observe"); if fault == "observe" { throw Fault.injected }; return observation }
    func disconnect() { events.append("disconnect") }
}
private func probeInputs() throws -> RecoveryBootInputs {
    let raw = try PinnedFELInputs.load()
    return .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage)
}
private actor ProbeWaitGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
    func ready() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !entered {
            guard ContinuousClock.now < deadline else { throw ProbeWaitFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    enum ProbeWaitFailure: Error { case timeout }
}
struct RecoveryRAMProbeTests {
    @Test func concurrentProbeIsRefusedBeforeItsInventory() async throws {
        let gate = ProbeWaitGate(), firstIO = ProbeSpy(devices: [[probeFEL()]]), secondIO = ProbeSpy()
        let service = RecoveryRAMProbe(wait: { await gate.wait() }), inputs = try probeInputs()
        let first = Task { try await service.run(inputs: inputs, io: firstIO) }
        do {
            try await gate.ready()
            await #expect(throws: RecoveryProbeError.self) { try await service.run(inputs: inputs, io: secondIO) }
            #expect(await secondIO.events.isEmpty)
            first.cancel(); await gate.resume()
            await #expect(throws: CancellationError.self) { try await first.value }
        } catch {
            first.cancel(); await gate.resume(); _ = try? await first.value
            throw error
        }
    }
    @Test func failedObservationValidationDisconnectsAndDoesNotRetry() async throws {
        let io = ProbeSpy(observation: "truncated")
        await #expect(throws: RecoveryProbeError.self) { try await RecoveryRAMProbe(wait: {}).run(inputs: probeInputs(), io: io) }
        #expect(await io.events == ["inventory","boot","inventory","inventory","connect","observe","disconnect"])
    }
    @Test func pinnedLoaderMatchesBundledRawFixture() async throws {
        let loaded = try await PayloadService.shared.pinnedRecoveryInputs(), raw = try probeInputs()
        #expect(loaded.fes1 == raw.fes1 && loaded.uboot == raw.uboot && loaded.bootImage == raw.bootImage)
    }
    @Test func invalidInputsNeverInventoryOrOpen() async {
        let io = ProbeSpy()
        await #expect(throws: (any Error).self) {
            try await RecoveryRAMProbe(wait: {}).run(inputs: .init(fes1: Data(), uboot: Data(), bootImage: Data()), io: io)
        }
        #expect(await io.events.isEmpty)
    }
    @Test func modeMultiplicityAndPortPolicyFailsClosed() throws {
        let normal = RecoveryProbeUSBDevice(vendorID: 0x1f3a, productID: 0xefe8, deviceVersion: 0x0233, deviceClass: 0,
                                            locationID: 123, product: "CLV-S-NESY")
        for devices in [[], [normal], [probeFEL(), probeFEL(location: 456)], [probeFEL(), probeRNDIS()], [probeRNDIS()]] {
            #expect(throws: (any Error).self) { try RecoveryProbePolicy.before(devices) }
        }
        let before = try RecoveryProbePolicy.before([probeFEL()])
        #expect(try RecoveryProbePolicy.after([], original: before) == nil)
        #expect(try RecoveryProbePolicy.after([probeFEL()], original: before) == nil)
        #expect(try RecoveryProbePolicy.after([probeRNDIS()], original: before) == probeRNDIS())
        for devices in [[probeRNDIS(location: 456)], [probeFEL(location: 456)], [probeRNDIS(), probeFEL()], [normal]] {
            #expect(throws: (any Error).self) { try RecoveryProbePolicy.after(devices, original: before) }
        }
    }
    @Test func observationRejectsMalformedBuildFlagsIdentityAndWritableStorage() throws {
        let valid = probeObservation()
        let result = try RecoveryProbePolicy.observation(valid)
        #expect(result.hwid == "0123456789abcdef0123456789abcdef")
        #expect(result.board == "dp-nes")
        var cases = [String(valid.dropLast(5)), valid + "extra\n", valid.replacingOccurrences(of: "BOARD=dp-nes", with: "BOARD=dp-nes\nBOARD=other"),
                     valid.replacingOccurrences(of: "BOARD=dp-nes", with: "OTHER=dp-nes"), String(repeating: "a", count: 65537), valid + "é"]
        for (old,new) in [("3.4.113.29-madmonkey","3.4.112"), ("hakchi-shell hakchi-memboot","hakchi-shell hakchi-install"),
                          ("hakchi-shell hakchi-memboot","hakchi-shell hakchi-memboot key=hakchi-install"),
                          ("hakchi-shell hakchi-memboot","hakchi-shell hakchi-memboot hakchi-shell"),
                          ("0123456789abcdef0123456789abcdef",String(repeating: "0", count: 32)),
                          ("0123456789abcdef0123456789abcdef","invalid"), ("NES_DIRECTORY=1","NES_DIRECTORY=0"),
                          ("ede443827300aff46995b97bb73c221aba2a1e9a38c710160a2fa28fdaec45b0",String(repeating: "a", count: 64)),
                          ("ro,noatime","rw,noatime"), ("/newroot squashfs","/other squashfs"),
                          ("MOUNTS_END","/dev/nandc /newroot/var/lib ext4 rw 0 0\nMOUNTS_END"),
                          ("MOUNTS_END","/dev/nandc /var/lib ext4 ro 0 0\nMOUNTS_END"),
                          ("MOUNTS_END","/dev/nandc /other ext4 rw 0 0\nMOUNTS_END")] {
            cases.append(valid.replacingOccurrences(of: old, with: new))
        }
        for bad in cases { #expect(throws: (any Error).self) { try RecoveryProbePolicy.observation(bad) } }
    }
    @Test func correctTransitionConnectsOnceObservesAndDisconnects() async throws {
        let io = ProbeSpy()
        let report = try await RecoveryRAMProbe(wait: {}).run(inputs: probeInputs(), io: io)
        #expect(report.observation.hwid.count == 32)
        #expect(await io.events == ["inventory","boot","inventory","inventory","connect","observe","disconnect"])
    }
    @Test(arguments: ["inventory","boot","connect","observe"])
    func everyFailureStopsWithoutRetryAndClosesConnectAttempt(step: String) async throws {
        let io = ProbeSpy(fault: step)
        await #expect(throws: ProbeSpy.Fault.self) { try await RecoveryRAMProbe(wait: {}).run(inputs: probeInputs(), io: io) }
        let events = await io.events
        #expect(events.filter { $0 == "boot" }.count <= 1)
        if events.contains("connect") { #expect(events.last == "disconnect") }
        if step == "boot" { #expect(!events.contains("connect")) }
    }
    @Test func transitionTimeoutAndCancellationNeverRetryBoot() async throws {
        let io = ProbeSpy(devices: [[probeFEL()]])
        await #expect(throws: (any Error).self) { try await RecoveryRAMProbe(wait: {}).run(inputs: probeInputs(), io: io, pollLimit: 2) }
        #expect(await io.events.filter { $0 == "boot" }.count == 1)
        #expect(await !io.events.contains("connect"))
        let cancelled = ProbeSpy(devices: [[probeFEL()]])
        await #expect(throws: CancellationError.self) {
            try await RecoveryRAMProbe(wait: { throw CancellationError() }).run(inputs: probeInputs(), io: cancelled)
        }
        #expect(await cancelled.events.filter { $0 == "boot" }.count == 1)
        #expect(await !cancelled.events.contains("connect"))
    }
}
