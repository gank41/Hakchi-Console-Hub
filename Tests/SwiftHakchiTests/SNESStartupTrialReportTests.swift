import Foundation
import Testing
@testable import SwiftHakchi

func startupTrialReportFixture(challenge:UUID,hwid:String=String(repeating:"1",count:32),runtime:String=String(repeating:"2",count:64),wrapper:String=String(repeating:"3",count:64))->Data {
    Data("""
    SWIFTHAKCHI_SNES_STARTUP_TRIAL_V1
    CHALLENGE=\(challenge.uuidString)
    KERNEL=3.4.113
    BOARD=dp-shvc
    REGION=USA
    HWID=\(hwid)
    RUNTIME_SHA=\(runtime)
    WRAPPER_SHA=\(wrapper)
    ROOT=verified
    INIT=original-busybox
    MCP_PID=101
    DAEMON_PID=102
    MODULES=clvcon,mali,sunxi_keyboard,sunxi_knob
    DEVICES=ready
    USB=verified-model-3
    PROFILE=existing
    TAINT=0
    MOUNTS_BEGIN
    /dev/mapper/root-crypt / squashfs ro,noatime 0 0
    devtmpfs /dev devtmpfs rw,relatime 0 0
    proc /proc proc rw,relatime 0 0
    sysfs /sys sysfs rw,relatime 0 0
    devpts /dev/pts devpts rw,relatime 0 0
    tmpfs /dev/shm tmpfs rw,relatime 0 0
    tmpfs /tmp tmpfs rw,relatime 0 0
    tmpfs /run tmpfs rw,relatime 0 0
    tmpfs /var tmpfs rw,relatime 0 0
    /dev/nandc /var/lib ext4 rw,nosuid,nodev,noatime 0 0
    tmpfs /mnt tmpfs rw,nosuid,nodev 0 0
    tmpfs /etc/init.d/S90usb-gadget tmpfs rw,nosuid,nodev 0 0
    MOUNTS_END
    END

    """.utf8)
}
struct SNESStartupTrialReportTests {
    private let expected=SNESStartupTrialExpectation(hwid:String(repeating:"1",count:32),runtimeSHA256:String(repeating:"2",count:64),wrapperSHA256:String(repeating:"3",count:64))
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_TRIAL_REPORT_EXECUTION_JSON"] != nil))
    func acceptsExecutedReportFromSyntheticOSFixture()throws {
        let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_TRIAL_REPORT_EXECUTION_JSON"])
        struct Execution:Decodable {let rawPath:String,hwid:String,runtimeSHA256:String,wrapperSHA256:String,challenge:String;let mcpPID:Int?,daemonPID:Int?}
        let e=try JSONDecoder().decode(Execution.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let report=try SNESStartupTrialReport(Data(contentsOf:URL(fileURLWithPath:e.rawPath)),expected:.init(hwid:e.hwid,runtimeSHA256:e.runtimeSHA256,wrapperSHA256:e.wrapperSHA256),challenge:#require(UUID(uuidString:e.challenge)))
        #expect(report.mcpPID==(e.mcpPID ?? 101) && report.daemonPID==(e.daemonPID ?? 102))
    }
    @Test func acceptsChallengeBoundNormalProfileAndRAMSupport()throws {
        let id=UUID(),report=try SNESStartupTrialReport(startupTrialReportFixture(challenge:id),expected:expected,challenge:id)
        #expect(report.mcpPID==101 && report.daemonPID==102)
    }
    @Test func acceptsOnlyTheExactUnderlyingRootfsEntryBeforeTheReadOnlyRoot()throws {
        let id=UUID(),base=String(decoding:startupTrialReportFixture(challenge:id),as:UTF8.self)
        let accepted=base.replacingOccurrences(of:"MOUNTS_BEGIN\n",with:"MOUNTS_BEGIN\nrootfs / rootfs rw 0 0\n")
        _=try SNESStartupTrialReport(Data(accepted.utf8),expected:expected,challenge:id)
        for rejected in [accepted.replacingOccurrences(of:"rootfs / rootfs rw 0 0",with:"rootfs / rootfs ro 0 0"),
            accepted.replacingOccurrences(of:"rootfs / rootfs rw 0 0",with:"rootfs / rootfs rw 0 0\nrootfs / rootfs rw 0 0"),
            base.replacingOccurrences(of:"MOUNTS_END",with:"rootfs / rootfs rw 0 0\nMOUNTS_END"),
            accepted.replacingOccurrences(of:"/dev/mapper/root-crypt / squashfs ro,noatime",with:"/dev/mapper/root-crypt / squashfs rw,noatime")] {
            #expect(throws:(any Error).self) {try SNESStartupTrialReport(Data(rejected.utf8),expected:expected,challenge:id)}
        }
    }
    @Test(arguments:["challenge","identity","kernel","runtime","wrapper","root-rw","data-ro","extra-data","duplicate","pid","end","oversized"])
    func refusesWrongIdentityProcessesOrMounts(_ fault:String)throws {
        let id=UUID();var s=String(decoding:startupTrialReportFixture(challenge:id),as:UTF8.self)
        switch fault {
        case "challenge":s=s.replacingOccurrences(of:id.uuidString,with:UUID().uuidString)
        case "identity":s=s.replacingOccurrences(of:"HWID="+expected.hwid,with:"HWID="+String(repeating:"4",count:32))
        case "kernel":s=s.replacingOccurrences(of:"KERNEL=3.4.113",with:"KERNEL=3.4.112")
        case "runtime":s=s.replacingOccurrences(of:"RUNTIME_SHA="+expected.runtimeSHA256,with:"RUNTIME_SHA="+String(repeating:"4",count:64))
        case "wrapper":s=s.replacingOccurrences(of:"WRAPPER_SHA="+expected.wrapperSHA256,with:"WRAPPER_SHA="+String(repeating:"4",count:64))
        case "root-rw":s=s.replacingOccurrences(of:"squashfs ro,noatime",with:"squashfs rw,noatime")
        case "data-ro":s=s.replacingOccurrences(of:"ext4 rw,nosuid",with:"ext4 ro,nosuid")
        case "extra-data":s=s.replacingOccurrences(of:"MOUNTS_END",with:"/dev/nandc /other ext4 rw 0 0\nMOUNTS_END")
        case "duplicate":s=s.replacingOccurrences(of:"MOUNTS_END",with:"tmpfs /mnt tmpfs rw 0 0\nMOUNTS_END")
        case "pid":s=s.replacingOccurrences(of:"DAEMON_PID=102",with:"DAEMON_PID=101")
        case "end":s+="extra\n"
        default:s=String(repeating:"a",count:20000)
        }
        #expect(throws:(any Error).self) {try SNESStartupTrialReport(Data(s.utf8),expected:expected,challenge:id)}
    }
}

struct SNESCleanMenuLaunchReportTests {
    private let expected=SNESStartupTrialExpectation(hwid:String(repeating:"1",count:32),runtimeSHA256:String(repeating:"2",count:64),
        wrapperSHA256:String(repeating:"3",count:64),deviceVersion:0x6a0a,menuWrapperSHA256:String(repeating:"4",count:64))
    private func fixture(_ id:UUID)->String {
        String(decoding:startupTrialReportFixture(challenge:id),as:UTF8.self)
            .replacingOccurrences(of:"MOUNTS_BEGIN\n",with:"MCP_SIGBLK=0000000000000000\nUI_SIGBLK=0000000000000000\nMOUNTS_BEGIN\n")
            .replacingOccurrences(of:"MOUNTS_END",with:"tmpfs /etc/init.d/S81clover-mcp tmpfs rw,nosuid,nodev 0 0\nMOUNTS_END")
    }
    @Test func acceptsOnlyExplicitCleanManagerAndFrontendMasks() throws {
        let id=UUID()
        let report=try SNESStartupTrialReport(Data(fixture(id).utf8),expected:expected,challenge:id)
        #expect(report.mcpPID==101 && report.daemonPID==102)
    }
    @Test(arguments:["MCP_SIGBLK","UI_SIGBLK"])
    func refusesCapturedBlockedShutdownSignals(_ field:String) throws {
        let id=UUID(),raw=fixture(id).replacingOccurrences(of:field+"=0000000000000000",with:field+"=0000000000004006")
        #expect(throws:(any Error).self) {try SNESStartupTrialReport(Data(raw.utf8),expected:expected,challenge:id)}
    }
    @Test(arguments:["missing","duplicate","malformed","short","extra"])
    func refusesAmbiguousSignalEvidence(_ fault:String) throws {
        let id=UUID();var raw=fixture(id)
        switch fault {
        case "missing":raw=raw.replacingOccurrences(of:"UI_SIGBLK=0000000000000000\n",with:"")
        case "duplicate":raw=raw.replacingOccurrences(of:"UI_SIGBLK=",with:"MCP_SIGBLK=")
        case "malformed":raw=raw.replacingOccurrences(of:"UI_SIGBLK=0000000000000000",with:"UI_SIGBLK=000000000000000g")
        case "short":raw=raw.replacingOccurrences(of:"UI_SIGBLK=0000000000000000",with:"UI_SIGBLK=0")
        default:raw=raw.replacingOccurrences(of:"MOUNTS_BEGIN",with:"EXTRA=0\nMOUNTS_BEGIN")
        }
        #expect(throws:(any Error).self) {try SNESStartupTrialReport(Data(raw.utf8),expected:expected,challenge:id)}
    }
    @Test func nativeArtworkRuntimeAlsoRequiresCleanMasks() throws {
        let id=UUID(),native=SNESStartupTrialExpectation(hwid:expected.hwid,runtimeSHA256:expected.runtimeSHA256,wrapperSHA256:expected.wrapperSHA256,deviceVersion:0x6a0b,menuWrapperSHA256:expected.menuWrapperSHA256)
        _=try SNESStartupTrialReport(Data(fixture(id).utf8),expected:native,challenge:id)
        let bad=fixture(id).replacingOccurrences(of:"UI_SIGBLK=0000000000000000",with:"UI_SIGBLK=0000000000004006")
        #expect(throws:(any Error).self) {try SNESStartupTrialReport(Data(bad.utf8),expected:native,challenge:id)}
    }
    @Test func historicalReportsDoNotAcceptNewFields() throws {
        let id=UUID(),old=SNESStartupTrialExpectation(hwid:expected.hwid,runtimeSHA256:expected.runtimeSHA256,wrapperSHA256:expected.wrapperSHA256)
        #expect(throws:(any Error).self) {try SNESStartupTrialReport(Data(fixture(id).utf8),expected:old,challenge:id)}
    }
}
