import Foundation
import Testing
import USBBridge
@testable import SwiftHakchi

func probeExpectationFixture() -> SNESRAMProbeExpectation {
    .init(binding: runtimeBindingFixture(), nonce: "22222222-2222-2222-2222-222222222222",
          hashes: Dictionary(uniqueKeysWithValues: ["INIT_SHA", "REPORT_SHA", "LOADER_SHA", "LIBC_SHA", "DAEMON_SHA", "BUSYBOX_SHA"].map { ($0, String(repeating: "a", count: 64)) }))
}
func probeRuntimeUSB() -> RecoveryProbeUSBDevice {
    .init(vendorID: 0x1f3a, productID: 0xefe8, deviceVersion: 0x6a01, deviceClass: 0,
          locationID: 123, product: "Swift Hakchi SNES RAM Probe", registryEntryID: 9003)
}
func probeReportFixture() -> String {
    let e = probeExpectationFixture()
    return "SWIFTHAKCHI_SNES_RAM_REPORT_V1\nNONCE=\(e.nonce)\nKERNEL=3.4.112.madmonkey\nBOARD=dp-shvc\nREGION=USA\nHWID=\(e.binding.expectedHWID)\n" +
        ["INIT_SHA", "REPORT_SHA", "LOADER_SHA", "LIBC_SHA", "DAEMON_SHA", "BUSYBOX_SHA"].map { "\($0)=\(e.hashes[$0]!)\n" }.joined() +
        "STATUS=ready\nMOUNTS_BEGIN\nrootfs / rootfs rw 0 0\ndevtmpfs /dev devtmpfs rw 0 0\nproc /proc proc rw 0 0\nsysfs /sys sysfs rw 0 0\n/dev/mapper/swifthakchi-probe-root /newroot squashfs ro,noatime 0 0\nMOUNTS_END\nEND\n"
}
private actor ProbeSessionIO: SNESRAMProbeIO {
    var events: [String] = [], reads = 0
    let fault: String
    init(_ fault: String) { self.fault = fault }
    func inventory() -> [RecoveryProbeUSBDevice] {
        events.append("inventory")
        if events.count == 1 { return [probeFEL()] }
        if fault == "port" { return [probeRNDIS()] }
        if fault == "extra" { return [probeRuntimeUSB(), probeRuntimeUSB()] }
        return [probeRuntimeUSB()]
    }
    func boot(expected: RecoveryProbeUSBDevice) { events.append("boot") }
    func connect(expected: RecoveryProbeUSBDevice) throws { events.append("connect"); if fault == "connect" { throw SNESRuntimeBinding.failure() } }
    func report() throws -> Data {
        events.append("report"); reads += 1
        if fault == "cancel" { throw CancellationError() }
        var text = probeReportFixture()
        if fault == "nonce" { text = text.replacingOccurrences(of: "NONCE=222", with: "NONCE=333") }
        if fault == "changed" && reads == 2 { text += "\n" }
        return Data(text.utf8)
    }
    func disconnect() { events.append("disconnect") }
}
struct SNESRAMProbeSessionTests {
    @Test func passiveBoundConstructorNeverClearsStalledEndpoint() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("passive-bound-test")
        let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = ["-Werror", "-Wno-unused-parameter", "-I", repo.appendingPathComponent("USBBridge/include").path,
            repo.appendingPathComponent("Tests/USBBridgeHarness/passive_bound.c").path, "-framework", "IOKit", "-framework", "CoreFoundation", "-o", executable.path]
        try compile.run(); compile.waitUntilExit(); try #require(compile.terminationStatus == 0)
        let run = Process(); run.executableURL = executable; run.standardError = FileHandle.nullDevice
        try run.run(); run.waitUntilExit(); #expect(run.terminationStatus == 0)
    }
    @Test func descriptorsAndPassiveOpenNeverFallBackToFEL() throws {
        let valid = probeRuntimeUSB()
        _ = try SNESRAMProbeUSBPolicy.nativeIdentity(valid)
        #expect(throws: (any Error).self) { try SNESRAMProbeUSBPolicy.nativeIdentity(probeFEL()) }
        #expect(throws: (any Error).self) { try SNESRAMProbeUSBPolicy.after([valid, valid], original: probeFEL()) }
        var error = HAKCHI_USB_OK
        #expect(hakchi_usb_open_passive_bound(nil, nil, &error) == nil)
        #expect(error == HAKCHI_USB_ERROR_INVALID_PARAM)
    }
    @Test func reportRejectsWrongNonceIdentityHashesMountsAndExtraFields() throws {
        let e = probeExpectationFixture(), valid = probeReportFixture()
        _ = try SNESRAMProbeReport(Data(valid.utf8), expected: e)
        for changed in [valid + "extra\n", valid.replacingOccurrences(of: "NONCE=222", with: "NONCE=333"),
                        valid.replacingOccurrences(of: "HWID=012", with: "HWID=112"),
                        valid.replacingOccurrences(of: "ro,noatime", with: "rw,noatime"),
                        valid.replacingOccurrences(of: "INIT_SHA=a", with: "INIT_SHA=b"),
                        valid.replacingOccurrences(of: "STATUS=ready", with: "STATUS=starting"),
                        valid.replacingOccurrences(of: "MOUNTS_END", with: "/dev/nandc /games ext4 rw 0 0\nMOUNTS_END")] {
            #expect(throws: (any Error).self) { try SNESRAMProbeReport(Data(changed.utf8), expected: e) }
        }
    }
    @Test(arguments: ["none", "port", "extra", "connect", "nonce", "changed", "cancel"])
    func sessionClosesOnceAndNeverRetries(_ fault: String) async throws {
        let io = ProbeSessionIO(fault)
        do {
            _ = try await SNESRAMProbeService(wait: {}).run(expected: probeExpectationFixture(), io: io)
            #expect(fault == "none")
        } catch { #expect(fault != "none") }
        #expect(await io.events.filter { $0 == "boot" }.count == 1)
        #expect(await io.events.filter { $0 == "disconnect" }.count == 1)
        if fault == "none" { #expect(await io.reads == 2) }
    }
}
