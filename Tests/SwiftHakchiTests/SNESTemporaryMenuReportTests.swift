import Foundation
import Testing
@testable import SwiftHakchi

let menuNonce = "33333333-3333-3333-3333-333333333333"
let menuChallenge = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
func menuExpectation() -> SNESTemporaryMenuExpectation {
    .init(binding: runtimeBindingFixture(), nonce: menuNonce,
          filesSHA256: String(repeating: "a", count: 64), sourceFilesSHA256: String(repeating: "b", count: 64))
}
func menuMounts() -> String {
    """
    rootfs / rootfs rw 0 0
    tmpfs /probe tmpfs rw,nosuid,nodev,size=16384k,mode=700 0 0
    devtmpfs /dev devtmpfs rw 0 0
    proc /proc proc rw 0 0
    sysfs /sys sysfs rw 0 0
    /dev/dm-0 /newroot squashfs ro,relatime 0 0
    devtmpfs /newroot/dev devtmpfs rw 0 0
    proc /newroot/proc proc rw 0 0
    sysfs /newroot/sys sysfs rw 0 0
    tmpfs /newroot/var tmpfs rw,nosuid,nodev,size=32768k,mode=755 0 0
    tmpfs /newroot/run tmpfs rw,nosuid,nodev,size=8192k,mode=755 0 0
    tmpfs /newroot/tmp tmpfs rw,nosuid,nodev,size=16384k 0 0
    tmpfs /newroot/dev/shm tmpfs rw,nosuid,nodev,size=8192k 0 0
    devpts /newroot/dev/pts devpts rw,nosuid,noexec 0 0
    tmpfs /newroot/etc/udev/rules.d tmpfs rw,nosuid,nodev,size=16384k,mode=700 0 0
    tmpfs /newroot/lib/udev/rules.d tmpfs rw,nosuid,nodev,size=16384k,mode=700 0 0
    tmpfs /newroot/run/swifthakchi tmpfs rw,nosuid,nodev,size=16384k,mode=700 0 0
    """ + "\n"
}
func menuReport(challenge: UUID = menuChallenge) -> Data {
    Data(("""
    SWIFTHAKCHI_SNES_MENU_REPORT_V1
    NONCE=33333333-3333-3333-3333-333333333333
    CHALLENGE=\(challenge.uuidString)
    KERNEL=3.4.112.madmonkey
    BOARD=dp-shvc
    REGION=USA
    HWID=\(runtimeBindingFixture().expectedHWID)
    FILES_SHA=\(String(repeating: "a", count: 64))
    SOURCE_FILES_SHA=\(String(repeating: "b", count: 64))
    STATUS=ready
    BLOCKS=readonly
    MODULES=clovercon,mali,sunxi_keyboard,sunxi_knob
    CONTROLLER=loaded-arguments:1,-1,2,-1;36;0;0;8;0
    BINDS=verified
    DEVICES=ready
    USB=verified-hvc-0
    PROFILE=temporary
    SUPERVISOR=busybox-init
    TAINT=4096
    MCP_PID=42
    DAEMON_PID=31
    FREE_KIB=20000
    TOTAL_KIB=120000
    MOUNTS_BEGIN
    """ + "\n" + menuMounts() + "MOUNTS_END\nEND\n").utf8)
}
struct SNESTemporaryMenuReportTests {
    @Test func validFreshReportAcceptsOnlyTheTemporaryRAMMounts() throws {
        let report = try SNESTemporaryMenuReport(menuReport(), expected: menuExpectation(), challenge: menuChallenge)
        #expect(report.raw == menuReport())
        #expect(report.freeKiB == 20000)
    }
    @Test(arguments: ["nonce", "challenge", "version", "writable-root", "persistent", "size", "duplicate", "missing", "taint", "menu", "memory", "unbounded", "extra", "truncated", "huge"])
    func invalidReportsNeverBecomeReady(fault: String) throws {
        var text = String(decoding: menuReport(), as: UTF8.self)
        switch fault {
        case "nonce": text = text.replacingOccurrences(of: menuNonce, with: menuChallenge.uuidString)
        case "challenge": text = text.replacingOccurrences(of: menuChallenge.uuidString, with: menuNonce)
        case "version": text = text.replacingOccurrences(of: "3.4.112.madmonkey", with: "3.4.113")
        case "writable-root": text = text.replacingOccurrences(of: "squashfs ro,", with: "squashfs rw,")
        case "persistent": text = text.replacingOccurrences(of: "MOUNTS_END", with: "/dev/nandc /data ext4 rw 0 0\nMOUNTS_END")
        case "size": text = text.replacingOccurrences(of: "size=32768k", with: "size=0")
        case "duplicate": text = text.replacingOccurrences(of: "MOUNTS_BEGIN", with: "STATUS=ready\nMOUNTS_BEGIN")
        case "missing": text = text.replacingOccurrences(of: "tmpfs /newroot/run/swifthakchi tmpfs rw,nosuid,nodev,size=16384k,mode=700 0 0\n", with: "")
        case "taint": text = text.replacingOccurrences(of: "TAINT=4096", with: "TAINT=2")
        case "menu": text = text.replacingOccurrences(of: "MCP_PID=42", with: "MCP_PID=0")
        case "memory": text = text.replacingOccurrences(of: "FREE_KIB=20000", with: "FREE_KIB=999999")
        case "unbounded": text = text.replacingOccurrences(of: "size=8192k", with: "size=100000k")
        case "extra": text += "trailing\n"
        case "truncated": text = String(text.dropLast(5))
        default: text += String(repeating: "A", count: 65536)
        }
        #expect(throws: (any Error).self) { try SNESTemporaryMenuReport(Data(text.utf8), expected: menuExpectation(), challenge: menuChallenge) }
    }
}
