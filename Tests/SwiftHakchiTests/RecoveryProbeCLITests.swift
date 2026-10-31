import Foundation
import Testing
@testable import SwiftHakchi

private actor OfflineProbeTrap: RecoveryProbeIO {
    func inventory() throws -> [RecoveryProbeUSBDevice] { Issue.record("Offline mode inventoried USB"); return [] }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) { Issue.record("Offline mode booted hardware") }
    func connect(expected: RecoveryProbeUSBDevice) { Issue.record("Offline mode connected") }
    func observe() -> String { Issue.record("Offline mode queried hardware"); return "" }
    func disconnect() { Issue.record("Offline mode touched hardware cleanup") }
}
struct RecoveryProbeCLITests {
    @Test func optionsDefaultToInspectAndRejectUnknownOrConflictingArguments() throws {
        #expect(try RecoveryDiagnosticOptions.parse([]) == .inspect)
        #expect(try RecoveryDiagnosticOptions.parse(["--inspect"]) == .inspect)
        #expect(try RecoveryDiagnosticOptions.parse(["--boot-recovery"]) == .boot)
        for args in [["--boot"], ["--inspect","--boot-recovery"], ["--boot-recovery","--boot-recovery"], ["--reset"], ["--help"]] {
            #expect(throws: (any Error).self) { try RecoveryDiagnosticOptions.parse(args) }
        }
    }
    @Test func inspectPreparesPinnedBytesWithoutCreatingNativeBoundary() async throws {
        let raw = try PinnedFELInputs.load()
        let text = try await RecoveryDiagnosticRunner.run(mode: .inspect,
            inputs: .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage), makeIO: {
                Issue.record("Inspect instantiated native I/O")
                return OfflineProbeTrap()
            })
        let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["mode"] as? String == "inspect")
        #expect(json["firmwareRestoreEligible"] as? Bool == false)
        #expect(json["rawBootSHA256"] as? String == "9e921c326be65aa4a3100270e86fdb15fe4b8563d586941b9f6c640eef064e4c")
        #expect((json["preparedBootSHA256"] as? String)?.count == 64)
    }
    @Test func descriptorDecodingRejectsIncompleteMatchingDevice() throws {
        let props: [String: Any] = ["idVendor": 0x1f3a, "idProduct": 0xefe8, "bcdDevice": 0x02b3, "bDeviceClass": 0, "locationID": 123]
        #expect(try RecoveryProbeUSBRegistry.device(from: props, registryEntryID: 9001) == probeFEL())
        var missing = props; missing.removeValue(forKey: "locationID")
        #expect(throws: (any Error).self) { try RecoveryProbeUSBRegistry.device(from: missing) }
        #expect(try RecoveryProbeUSBRegistry.device(from: ["idVendor": 1,"idProduct": 2]) == nil)
    }
    @Test func actualQueryFormatsBoardFileWithoutTrailingNewline() throws {
        let stubs = #"""
        uname() { printf '3.4.113.29-madmonkey\n'; }
        cat() {
          case "$1" in
            /proc/cmdline) printf 'ro hakchi-shell hakchi-memboot\n';;
            /newroot/etc/clover/boardtype) printf 'dp-nes';;
            /proc/mounts) printf '/dev/nandb /newroot squashfs ro 0 0\n';;
            *) exit 3;;
          esac
        }
        sha256sum() {
          case "$1" in
            /hakchi/init) printf 'ede443827300aff46995b97bb73c221aba2a1e9a38c710160a2fa28fdaec45b0  file\n';;
            /hakchi/rootfs/etc/preinit.d/b0000_defines) printf '14a1dd7e3dae28339312fc379087c3e37119ce5684286e09a521f8cda318ae62  file\n';;
            *) exit 3;;
          esac
        }
        test() { [ "$1" = '-d' ] && [ "$2" = '/newroot/usr/share/games/nes/kachikachi' ]; }
        sntool() { printf '\001\000\000\000\002\000\000\000\003\000\000\000\004\000\000\000'; }
        """#
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", stubs + "\n" + RecoveryProbeCommand.observation]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let result = try RecoveryProbePolicy.observation(String(decoding: data, as: UTF8.self))
        #expect(result.board == "dp-nes" && result.hwid == "00000001000000020000000300000004")
    }
    @Test func fixedCommandParsesAndDoesNotInvokeMutationWrappers() throws {
        let command = RecoveryProbeCommand.observation
        for forbidden in ["source ", "hakchi hwid", "hakchi get", "mount ", "burn_", "flashBoot", "reboot", "rm ", " > /", "cat >", "install "] {
            #expect(!command.contains(forbidden))
        }
        #expect(command.contains("/proc/mounts"))
        #expect(command.contains("sntool devmem 0x01c23800 32"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
