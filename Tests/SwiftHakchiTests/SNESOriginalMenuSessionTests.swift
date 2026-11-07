import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func originalMenuReportFixture(expected: SNESOriginalMenuExpectation, challenge: UUID, state: SNESOriginalMenuState) -> Data {
    let baseline = Data("SNES_PRE_MENU_BEGIN\nPOWER_SWITCH=1\n\nMEMORY_BEGIN\nMemTotal: 262144 kB\nMemFree: 200000 kB\n\nINPUT_BEGIN\nNintendo Clovercon - controller1\n\nKERNEL_BEGIN\nfixture kernel\nSNES_PRE_MENU_END\n".utf8)
    let fields = ["NONCE=\(expected.nonce)", "CHALLENGE=\(challenge.uuidString)", "KERNEL=3.4.113", "BOARD=dp-shvc", "REGION=USA", "HWID=\(expected.binding.expectedHWID)",
        "FILES_SHA=\(expected.filesSHA256)", "SOURCE_FILES_SHA=\(expected.sourceFilesSHA256)", "COMPONENTS_SHA=\(expected.componentsSHA256)",
        "STATE=\(state.rawValue)", "BLOCKS=readonly", "MODULES=clvcon,mali,sunxi_keyboard,sunxi_knob", "CONTROLLER=loaded-arguments:1,195,2,194", "BINDS=verified", "DEVICES=ready", "USB=verified-model-3", "PROFILE=temporary", "SUPERVISOR=busybox-init", "TAINT=4096", "MCP_PID=\(state == .preMenu ? 0 : 101)", "DAEMON_PID=100"]
    let mounts = String(decoding: menuReport(challenge: challenge), as: UTF8.self).components(separatedBy: "MOUNTS_BEGIN\n")[1]
    return Data(("SWIFTHAKCHI_SNES_ORIGINAL_MENU_V1\n" + fields.joined(separator: "\n") + "\nBASELINE \(baseline.count) \(BackupManifest.digest(baseline))\n").utf8) + baseline + Data(("\nMOUNTS_BEGIN\n" + mounts).utf8)
}
func originalMenuExpectationFixture() -> SNESOriginalMenuExpectation {
    .init(binding: runtimeBindingFixture(), nonce: menuNonce, filesSHA256: String(repeating: "a",count:64), sourceFilesSHA256: String(repeating:"b",count:64), componentsSHA256:String(repeating:"c",count:64))
}
struct SNESOriginalMenuReportTests {
    @Test(arguments: [SNESOriginalMenuState.preMenu, .ready])
    func reportBindsStockKernelStateAndCheckpoint(state: SNESOriginalMenuState) throws {
        let expected = originalMenuExpectationFixture(), challenge = UUID()
        let report = try SNESOriginalMenuReport(originalMenuReportFixture(expected: expected, challenge: challenge, state: state), expected: expected, challenge: challenge, state: state)
        #expect(report.baseline.starts(with: Data("SNES_PRE_MENU_BEGIN\nPOWER_SWITCH=1\n".utf8)))
    }
    @Test(arguments: ["nonce", "challenge", "kernel", "usb", "controller", "module", "state", "hash", "count", "duplicate", "mount", "trailing", "budget"])
    func malformedOrLegacyReportsCannotGrantReadiness(fault: String) throws {
        let expected = originalMenuExpectationFixture(), challenge = UUID()
        var text = String(decoding: originalMenuReportFixture(expected: expected, challenge: challenge, state: .preMenu),as:UTF8.self)
        switch fault {
        case "nonce": text = text.replacingOccurrences(of: expected.nonce,with:UUID().uuidString)
        case "challenge": text = text.replacingOccurrences(of:challenge.uuidString,with:UUID().uuidString)
        case "kernel":text = text.replacingOccurrences(of:"KERNEL=3.4.113",with:"KERNEL=3.4.112.madmonkey")
        case "usb":text = text.replacingOccurrences(of:"verified-model-3",with:"verified-hvc-0")
        case "controller":text = text.replacingOccurrences(of:"loaded-arguments:1,195,2,194",with:"loaded-arguments:1,-1,2,-1")
        case "module":text = text.replacingOccurrences(of:"MODULES=clvcon,",with:"MODULES=clovercon,")
        case "state":text = text.replacingOccurrences(of:"STATE=pre-menu",with:"STATE=ready")
        case "hash":text = text.replacingOccurrences(of:"fixture kernel",with:"changed kernel")
        case "count":text = text.replacingOccurrences(of:"BASELINE ",with:"BASELINE 0")
        case "duplicate":text = text.replacingOccurrences(of:"BOARD=dp-shvc\n",with:"BOARD=dp-shvc\nBOARD=dp-shvc\n")
        case "mount":text = text.replacingOccurrences(of:"MOUNTS_END",with:"/dev/nandc /elsewhere ext4 ro 0 0\nMOUNTS_END")
        case "trailing":text += "extra\n"
        default:text = String(repeating:"a",count:65537)
        }
        #expect(throws:(any Error).self) { _ = try SNESOriginalMenuReport(Data(text.utf8),expected:expected,challenge:challenge,state:.preMenu) }
    }
}
actor OriginalMenuFakeIO: SNESOriginalMenuIO {
    let menu: PreparedSNESOriginalMenu, fault: String
    var events:[String]=[], inventories=0, reports=0
    let live:Bool,gate:OriginalMenuTestGate?
    init(menu:PreparedSNESOriginalMenu,fault:String="none",live:Bool=false,gate:OriginalMenuTestGate?=nil) { self.menu=menu;self.fault=fault;self.live=live;self.gate=gate }
    func inventory() throws -> [RecoveryProbeUSBDevice] {
        events.append("inventory");inventories += 1
        if fault == "inventory" { throw SNESRuntimeBinding.failure() }
        if inventories == 1 && !live { return [probeFEL()] }
        let good = RecoveryProbeUSBDevice(vendorID:0x1f3a,productID:0xefe8,deviceVersion:fault == "legacy-usb" ? 0x6a02:0x6a03,deviceClass:0,locationID:probeFEL().locationID,product:"Swift Hakchi SNES Original Menu Test",registryEntryID:999)
        return [good]
    }
    func boot(expected:RecoveryProbeUSBDevice) throws { events.append("boot");if fault=="boot" { throw SNESRuntimeBinding.failure() } }
    func connect(expected:RecoveryProbeUSBDevice) throws { events.append("connect");if fault=="connect" { throw SNESRuntimeBinding.failure() } }
    func checkpoint(challenge:UUID) async throws -> Data {
        events.append("checkpoint");if let gate {await gate.pause()}
        if fault=="cancel" { throw CancellationError() }
        if fault=="partial" { throw SNESOriginalMenuReadFailure(received:Data("partial".utf8),details:Data("fixture".utf8)) }
        let data=originalMenuReportFixture(expected:menu.expectation,challenge:challenge,state:.preMenu)
        if ["capture-details","capture-no-logs"].contains(fault) {
            let baseline=try SNESOriginalMenuReport(data,expected:menu.expectation,challenge:challenge,state:.preMenu).baseline
            let extended=Data(baseline.dropLast("SNES_PRE_MENU_END\n".utf8.count))+startupDetailsFixture()+Data("SNES_PRE_MENU_END\n".utf8)
            var text=String(decoding:data,as:UTF8.self)
            text=text.replacingOccurrences(of:"BASELINE \(baseline.count) \(BackupManifest.digest(baseline))\n"+String(decoding:baseline,as:UTF8.self),with:"BASELINE \(extended.count) \(BackupManifest.digest(extended))\n"+String(decoding:extended,as:UTF8.self))
            return Data(text.utf8)
        }
        return fault=="checkpoint" ? Data(data.dropLast()):data
    }
    func launch(_ request:SNESOriginalMenuLaunchRequest) throws {
        if fault=="receipt" { try Data([1]).write(to:request.checkpointDirectory.appendingPathComponent("checkpoint.bin")) }
        try request.validateCurrent()
        #expect(FileManager.default.fileExists(atPath:request.checkpointDirectory.appendingPathComponent("manifest.json").path))
        events.append("launch")
        if fault=="launch" { throw SNESOriginalMenuReadFailure(received:Data(),details:Data("lost after launch".utf8)) }
    }
    func report(challenge:UUID) throws -> Data {
        events.append("report");reports += 1
        let data=originalMenuReportFixture(expected:menu.expectation,challenge:challenge,state:.ready)
        return fault=="report" || fault=="second-report" && reports==2 ? Data(data.dropLast()):data
    }
    func diagnostics() -> Data { events.append("diagnostics");return ["missing-diagnostics","capture-no-logs"].contains(fault) ? Data():originalMenuDiagnosticsFixture(nonce:menu.nonce) }
    func disconnect() { events.append("disconnect") }
}
@Suite(.serialized)
struct SNESOriginalMenuSessionTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_COMPONENTS"] != nil))
    func failedResultVerificationCannotLeaveCompletedMenuRecord() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let menu=try #require(try privateOriginalMenu())
        let store=try RecoveryBootSnapshotStore(root:root)
        let result=try await SNESOriginalMenuService(wait:{}).start(menu:menu,store:store,io:OriginalMenuFakeIO(menu:menu,fault:"none"))
        await #expect(throws:(any Error).self) {
            try await store.saveSNESOriginalMenuResult(result,menu:menu,verify:{_ in throw RecoveryProbeError.refused("verification failed")})
        }
        let folders=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter{$0.lastPathComponent.hasPrefix("SNES-Original-Menu-Result-")}
        #expect(folders.count==1)
        #expect(folders.allSatisfy{!FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path)})
        await #expect(throws:(any Error).self) {
            try await store.saveSNESOriginalMenuResult(result,menu:menu,verify:{directory in
                try Data([1]).write(to:directory.appendingPathComponent("report-0.bin"))
            })
        }
        let partial=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter{$0.lastPathComponent.hasPrefix("SNES-Original-Menu-Result-")}
        #expect(partial.count==2)
        #expect(partial.allSatisfy{!FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path)})
        let checkpointFile=result.checkpointDirectory.appendingPathComponent("checkpoint.bin")
        let checkpointBytes=try Data(contentsOf:checkpointFile)
        await #expect(throws:(any Error).self) {
            try await store.saveSNESOriginalMenuResult(result,menu:menu,verify:{_ in try Data([1]).write(to:checkpointFile)})
        }
        try checkpointBytes.write(to:checkpointFile)
        let allPartial=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter{$0.lastPathComponent.hasPrefix("SNES-Original-Menu-Result-")}
        #expect(allPartial.count==3)
        #expect(allPartial.allSatisfy{!FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path)})
        let started=try await store.saveSNESOriginalMenuResult(result,menu:menu)
        #expect(try SNESOriginalMenuResult.loadStarted(directory:started,menu:menu).reports==result.reports)
        let after=SNESOriginalMenuResult(checkpoint:result.checkpoint,checkpointDirectory:result.checkpointDirectory,
            challenges:result.challenges,reports:result.reports,diagnostics:result.diagnostics,phase:"after-gameplay")
        let afterPath=try await store.saveSNESOriginalMenuResult(after,menu:menu)
        let record=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:afterPath.appendingPathComponent("manifest.json"))) as? [String:Any])
        #expect(record["phase"] as? String == "after-gameplay" && record["complete"] as? Bool == true)
    }
    @Test func checkpointIsDurableBeforeLaunchAndEveryFailureClosesWithoutRetry() async throws {
        guard let menu=try privateOriginalMenu() else { return }
        for fault in ["none","inventory","boot","legacy-usb","connect","cancel","partial","checkpoint","receipt","launch","report","second-report"] {
            let root=try testDirectory();defer { try? FileManager.default.removeItem(at:root) }
            let io=OriginalMenuFakeIO(menu:menu,fault:fault)
            do {
                let result=try await SNESOriginalMenuService(wait:{}).start(menu:menu,store:RecoveryBootSnapshotStore(root:root),io:io)
                #expect(fault=="none");#expect(result.reports.count==2)
                let path=try await RecoveryBootSnapshotStore(root:root).saveSNESOriginalMenuResult(result,menu:menu)
                #expect(try SNESOriginalMenuResult.loadStarted(directory:path,menu:menu).reports==result.reports)
            } catch is CancellationError { #expect(fault=="cancel") }
            catch let failure as SNESOriginalMenuFailure {
                #expect(fault != "none")
                let saved=try await RecoveryBootSnapshotStore(root:root).saveSNESOriginalMenuFailure(failure,menu:menu)
                #expect(FileManager.default.fileExists(atPath:saved.appendingPathComponent("manifest.json").path))
                if ["launch","report","second-report"].contains(fault) { #expect(failure.checkpoint != nil) }
                if fault=="partial" { #expect(failure.report==Data("partial".utf8)) }
            }
            let events=await io.events
            #expect(events.filter{$0=="disconnect"}.count==1)
            #expect(events.filter{$0=="boot"}.count<=1)
            #expect(events.filter{$0=="launch"}.count<=1)
            if ["inventory","boot","legacy-usb","connect","cancel","partial","checkpoint","receipt"].contains(fault) { #expect(!events.contains("launch")) }
        }
    }
    @Test func failedDurableCheckpointNeverReleasesTheMenu() async throws {
        guard let menu=try privateOriginalMenu() else { return }
        let root=try testDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let io=OriginalMenuFakeIO(menu:menu),store=try RecoveryBootSnapshotStore(root:root,synchronize:{_ in -1})
        await #expect(throws:(any Error).self) { _=try await SNESOriginalMenuService(wait:{}).start(menu:menu,store:store,io:io) }
        #expect(!(await io.events).contains("launch"))
        #expect((await io.events).filter{$0=="disconnect"}.count==1)
    }
}

actor OriginalMenuTestGate {
    private var paused=false,entered:CheckedContinuation<Void,Never>?,waiting:CheckedContinuation<Void,Never>?
    func pause() async {paused=true;entered?.resume();entered=nil;await withCheckedContinuation{waiting=$0}}
    func waitUntilPaused() async {if !paused {await withCheckedContinuation{entered=$0}}}
    func release(){waiting?.resume();waiting=nil}
}
func copiedOriginalMenu(_ original:PreparedSNESOriginalMenu,root:URL) throws -> PreparedSNESOriginalMenu {
    let copied=root.appendingPathComponent(original.material.components.directoryURL.lastPathComponent)
    try FileManager.default.copyItem(at:original.material.components.directoryURL,to:copied)
    let components=try SNESOriginalComponentMaterial.load(source:original.material.components.source,directory:copied)
    let material=try SNESOriginalMenuMaterial(components:components,runtime:original.material.runtime)
    let env=ProcessInfo.processInfo.environment,pinned=try PinnedFELInputs.load()
    return try SNESOriginalMenuRecipe.prepare(material:material,
        daemonHmod:Data(contentsOf:URL(fileURLWithPath:try #require(env["SWIFTHAKCHI_SNES_CLOVERSHELL"]))),
        busybox:Data(contentsOf:URL(fileURLWithPath:try #require(env["SWIFTHAKCHI_SNES_BUSYBOX"]))),
        recovery:.init(fes1:pinned.fes1,uboot:pinned.uboot,bootImage:pinned.bootImage))
}
extension SNESOriginalMenuSessionTests {
    @Test func lateFailureRetainsEveryReadyReport() async throws {
        guard let menu=try privateOriginalMenu() else{return}
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        do { _=try await SNESOriginalMenuService(wait:{}).start(menu:menu,store:RecoveryBootSnapshotStore(root:root),io:OriginalMenuFakeIO(menu:menu,fault:"second-report"));Issue.record("Accepted partial second report") }
        catch let failure as SNESOriginalMenuFailure {
            let exported=try failure.checkedExport(menu:menu)
            #expect(exported.files["report-0.bin"]?.starts(with:Data("SWIFTHAKCHI_SNES_ORIGINAL_MENU_V1\n".utf8))==true)
        }
    }
    @Test func reentrancyDoesNotBootTheSecondIOAndPostGameCheckNeverLaunches() async throws {
        guard let menu=try privateOriginalMenu() else{return}
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let store=try RecoveryBootSnapshotStore(root:root),gate=OriginalMenuTestGate(),service=SNESOriginalMenuService(wait:{})
        let first=OriginalMenuFakeIO(menu:menu,gate:gate),second=OriginalMenuFakeIO(menu:menu)
        let task=Task {try await service.start(menu:menu,store:store,io:first)}
        await gate.waitUntilPaused()
        await #expect(throws:(any Error).self) { _=try await service.start(menu:menu,store:store,io:second) }
        #expect(await second.events.isEmpty)
        await gate.release();let started=try await task.value
        let live=OriginalMenuFakeIO(menu:menu,live:true)
        let checked=try await service.check(menu:menu,started:started,store:store,io:live)
        #expect(checked.phase=="after-gameplay")
        let events=await live.events
        #expect(!events.contains("boot") && !events.contains("checkpoint") && !events.contains("launch"))
        #expect(events.filter{$0=="report"}.count==2 && events.filter{$0=="disconnect"}.count==1)
    }
    @Test func changedSourcesAtAwaitCommitAndCloseNeverBecomeSuccess() async throws {
        guard let original=try privateOriginalMenu() else{return}
        for boundary in ["await","commit","closing"] {
            let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
            let menu=try copiedOriginalMenu(original,root:root),changed=menu.material.components.directoryURL.appendingPathComponent("components.frame")
            let gate=OriginalMenuTestGate(),io=OriginalMenuFakeIO(menu:menu,gate:boundary=="await" ? gate:nil)
            let store=try RecoveryBootSnapshotStore(root:root,synchronize:{fd in
                if boundary=="commit" {try? Data([1]).write(to:changed)}
                return fsync(fd)
            })
            let task=Task {try await SNESOriginalMenuService(wait:{}).start(menu:menu,store:store,io:io,progress:{event in
                if boundary=="closing" && event == .closing {try? Data([1]).write(to:changed)}
            })}
            if boundary=="await" {await gate.waitUntilPaused();try Data([1]).write(to:changed);await gate.release()}
            do {_=try await task.value;Issue.record("Changed source accepted")}
            catch let failure as SNESOriginalMenuFailure {
                let saved=try await RecoveryBootSnapshotStore(root:root).saveSNESOriginalMenuFailure(failure,menu:menu)
                #expect(FileManager.default.fileExists(atPath:saved.appendingPathComponent("manifest.json").path))
            }
            let events=await io.events
            #expect(events.filter{$0=="disconnect"}.count==1 && events.contains("diagnostics")==["closing"].contains(boundary))
            if boundary != "closing" {#expect(!events.contains("launch"))}
        }
    }
}

extension SNESOriginalMenuReportTests {
    @Test func actualARMEmittedFramesUseTheSameStrictHostDecoder() throws {
        guard let path=ProcessInfo.processInfo.environment["SWIFTHAKCHI_ORIGINAL_MENU_ARM_FRAMES"] else{return}
        let root=URL(fileURLWithPath:path)
        let values=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("expectation.json"))) as? [String:String])
        _=try SNESOriginalMenuDiagnostics(Data(contentsOf:root.appendingPathComponent("diagnostic.frame")),nonce:try #require(values["nonce"]))
        let base=runtimeBindingFixture(),hash=try #require(values["filesSHA256"])
        let binding=SNESRuntimeBinding(sourceSnapshot:base.sourceSnapshot,setupManifestSHA256:base.setupManifestSHA256,expectedHWID:try #require(values["hwid"]))
        let expected=SNESOriginalMenuExpectation(binding:binding,nonce:try #require(values["nonce"]),filesSHA256:hash,sourceFilesSHA256:hash,componentsSHA256:hash)
        let challengeText=try #require(values["challenge"])
        let challenge=try #require(UUID(uuidString:challengeText))
        for state in [SNESOriginalMenuState.preMenu,.ready] {
            let report=try SNESOriginalMenuReport(Data(contentsOf:root.appendingPathComponent(state.rawValue+".frame")),expected:expected,challenge:challenge,state:state)
            #expect(report.baseline.range(of:Data("ARM synthetic fixture".utf8)) != nil)
        }
    }
}

extension SNESOriginalMenuSessionTests {
    @Test func successRequiresRetainedDiagnosticsAndMissingLogsPreserveReports() async throws {
        guard let menu=try privateOriginalMenu() else{return}
        for fault in ["none","missing-diagnostics"] {
            let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
            let io=OriginalMenuFakeIO(menu:menu,fault:fault)
            do {
                let result=try await SNESOriginalMenuService(wait:{}).start(menu:menu,store:RecoveryBootSnapshotStore(root:root),io:io)
                #expect(fault=="none")
                let exported=try result.checkedExport(menu:menu)
                #expect(exported.files["diagnostic.log"]?.isEmpty==false)
            } catch let failure as SNESOriginalMenuFailure {
                #expect(fault=="missing-diagnostics")
                #expect(failure.capturedReports.count==2)
            }
            #expect((await io.events).contains("diagnostics"))
            #expect((await io.events).filter{$0=="disconnect"}.count==1)
        }
    }
}

func originalMenuDiagnosticsFixture(nonce:String) -> Data {
    var raw=Data("SWIFTHAKCHI_ORIGINAL_LOGS_V1\nNONCE=\(nonce)\n".utf8)
    for name in ["startup-stages","init.log","daemon.log","udev.log","menu.log","kernel"] {
        let bytes=Data((name=="startup-stages" ? "ready":name=="kernel" ? "kernel fixture":"").utf8)
        raw+=Data("LOG \(name) \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8)+bytes+Data([10])
    }
    return raw+Data("END\n".utf8)
}

struct SNESOriginalMenuDiagnosticsTests {
    @Test func boundedLogsRejectTruncationMissingSectionsAndChangedContent() throws {
        let nonce=UUID().uuidString,raw=originalMenuDiagnosticsFixture(nonce:nonce)
        _=try SNESOriginalMenuDiagnostics(raw,nonce:nonce)
        let stderr=Data([0,10,255])+Data("startup messages".utf8)
        let retained=try SNESOriginalMenuDiagnostics.appendingStderr(stderr,to:raw,nonce:nonce)
        #expect(retained.range(of:stderr) != nil)
        for bytes in [Data(),Data(raw.dropLast()),raw+Data([10]),Data(String(decoding:raw,as:UTF8.self).replacingOccurrences(of:"kernel fixture",with:"changed kernel").utf8),Data(String(decoding:raw,as:UTF8.self).replacingOccurrences(of:"LOG menu.log",with:"LOG missing").utf8),Data(repeating:0,count:65537)] {
            #expect(throws:(any Error).self){_=try SNESOriginalMenuDiagnostics(bytes,nonce:nonce)}
        }
        #expect(throws:(any Error).self){_=try SNESOriginalMenuDiagnostics(raw,nonce:UUID().uuidString)}
    }
    @Test func actualLogScriptRequiresFilesAndSuccessfulProducers() throws {
        let nonce=UUID().uuidString
        for fault in ["none","missing","linked","hardlink","hash","kernel"] {
            let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
            try Data(nonce.utf8).write(to:root.appendingPathComponent("nonce"))
            for name in ["startup-stages","init.log","daemon.log","udev.log","menu.log"] {
                try Data((name=="startup-stages" ? "ready":"").utf8).write(to:root.appendingPathComponent(name))
            }
            let menu=root.appendingPathComponent("menu.log")
            if fault=="missing" {try FileManager.default.removeItem(at:menu)}
            if fault=="linked" {try FileManager.default.removeItem(at:menu);try FileManager.default.createSymbolicLink(at:menu,withDestinationURL:root.appendingPathComponent("init.log"))}
            if fault=="hardlink" {try FileManager.default.linkItem(at:menu,to:root.appendingPathComponent("linked.log"))}
            let wrapper="""
            #!/bin/bash
            cmd="$1"; shift
            case "$cmd" in
              wc) /usr/bin/wc "$@" | /usr/bin/xargs;;
              stat) exec /usr/bin/stat -f '%z:%l' "$3";;
              sha256sum) /usr/bin/shasum -a 256 "$@"; exit \(fault=="hash" ? 9:0);;
              dmesg) printf 'kernel fixture'; exit \(fault=="kernel" ? 9:0);;
              *) exec "$cmd" "$@";;
            esac
            """
            let bb=root.appendingPathComponent("busybox");try Data(wrapper.utf8).write(to:bb)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:bb.path)
            let process=Process(),pipe=Pipe()
            process.executableURL=URL(fileURLWithPath:"/bin/bash")
            process.arguments=["-c",SNESOriginalMenuScripts.diagnostics.replacingOccurrences(of:"/probe/",with:root.path+"/")]
            process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            #expect((process.terminationStatus==0)==(fault=="none"))
            if fault=="none" {_=try SNESOriginalMenuDiagnostics(data,nonce:nonce)}
            else {#expect(throws:(any Error).self){_=try SNESOriginalMenuDiagnostics(data,nonce:nonce)}}
        }
    }
}

extension SNESOriginalMenuDiagnosticsTests {
    @Test func originalKernelWithoutSyslogRecordsExplicitAbsenceAndOtherFailuresStillRefuse() throws {
        for mode in ["supported","enosys","permission","empty","bad-option","failed-output"] {
            let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
            let nonce=UUID().uuidString
            for (name,text) in [("nonce",nonce),("power","1"),("memory","MemTotal: 262144 kB\n"),("input","input fixture\n"),("startup-stages","ready"),("init.log",""),("daemon.log",""),("udev.log",""),("menu.log","")] {
                try Data(text.utf8).write(to:root.appendingPathComponent(name))
            }
            let command:String
            switch mode {
            case "supported":command="printf 'real kernel text'; exit 0"
            case "enosys":command="printf 'dmesg: klogctl: Function not implemented\\n' >&2; exit 1"
            case "permission":command="printf 'dmesg: klogctl: Operation not permitted\\n' >&2; exit 1"
            case "empty":command="exit 0"
            case "bad-option":command="printf 'dmesg: invalid option -- s\\n' >&2; exit 1"
            default:command="printf 'real kernel text'; exit 9"
            }
            let wrapper="""
            #!/bin/bash
            cmd="$1"; shift
            case "$cmd" in
              wc) /usr/bin/wc "$@" | /usr/bin/xargs;;
              stat) exec /usr/bin/stat -f '%z:%l' "$3";;
              sha256sum) exec /usr/bin/shasum -a 256 "$@";;
              dmesg) \(command);;
              *) exec "$cmd" "$@";;
            esac
            """
            let bb=root.appendingPathComponent("busybox");try Data(wrapper.utf8).write(to:bb)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:bb.path)
            let baseline=SNESOriginalMenuScripts.checkpointHelpers
                .replacingOccurrences(of:"/probe/",with:root.path+"/")
                .replacingOccurrences(of:"/sys/devices/knob/power_switch",with:root.appendingPathComponent("power").path)
                .replacingOccurrences(of:"/proc/meminfo",with:root.appendingPathComponent("memory").path)
                .replacingOccurrences(of:"/proc/bus/input/devices",with:root.appendingPathComponent("input").path)
            let scripts=["set -eu\nB='\(bb.path)'\nfail(){ exit 9; }\n"+baseline+"\ncapture_startup_details(){ :; }\ncapture_menu_baseline\ncat '"+root.appendingPathComponent("menu-baseline").path+"'\n",
                         SNESOriginalMenuScripts.diagnostics.replacingOccurrences(of:"/probe/",with:root.path+"/")]
            for (index,script) in scripts.enumerated() {
                let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/bash")
                process.arguments=["-c",script];process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
                try process.run();let bytes=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                let accepted=["supported","enosys"].contains(mode)
                #expect((process.terminationStatus==0)==accepted,"mode=\(mode) script=\(index)")
                if accepted && process.terminationStatus==0 {
                    if index==1 {_=try SNESOriginalMenuDiagnostics(bytes,nonce:nonce)}
                    #expect(bytes.range(of:Data((mode=="enosys" ? "SNES_KERNEL_LOG_UNAVAILABLE=ENOSYS":"real kernel text").utf8)) != nil)
                }
            }
        }
    }
}

struct SNESStartupDetailsTests {
    @Test func fixedRecordsBindPathsCountsAndContent() throws {
        let raw=startupDetailsFixture()
        _=try SNESStartupDetails(raw)
        for bad in [Data(),Data(raw.dropLast()),raw+Data([10]),Data(String(decoding:raw,as:UTF8.self).replacingOccurrences(of:"settings fixture",with:"changed settings").utf8),Data(String(decoding:raw,as:UTF8.self).replacingOccurrences(of:"FILE /proc/cmdline",with:"FILE /proc/other").utf8)] {
            #expect(throws:(any Error).self){_=try SNESStartupDetails(bad)}
        }
    }
    @Test func captureNeverLaunchesOrClaimsAWorkingMenu() async throws {
        guard let menu=try privateOriginalMenu() else {return}
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let store=try RecoveryBootSnapshotStore(root:root),io=OriginalMenuFakeIO(menu:menu,fault:"capture-details")
        let result=try await SNESOriginalMenuService(wait:{}).captureStartup(menu:menu,store:store,io:io)
        let exported=try result.checkedExport(menu:menu)
        #expect(exported.files["startup-details.bin"]==startupDetailsFixture())
        let manifest=try #require(JSONSerialization.jsonObject(with:exported.manifest) as? [String:Any])
        #expect(manifest["scope"] as? String == "snes-startup-details")
        #expect(manifest["menuLaunched"] as? Bool == false)
        #expect(manifest["firmwareWritten"] as? Bool == false)
        let events=await io.events
        #expect(!events.contains("launch") && !events.contains("report"))
        #expect(events.filter{$0=="disconnect"}.count==1)
    }
}
func startupDetailsFixture() -> Data {
    var bytes=Data("SNES_STARTUP_DETAILS_BEGIN\n".utf8)
    for (path,max) in [("/proc/cmdline",1024),("/sys/class/graphics/fb0/name",128),("/sys/class/graphics/fb0/virtual_size",128),("/sys/class/graphics/fb0/bits_per_pixel",128),("/usr/share/applications/clover-mcp.desktop",4096),("/usr/share/applications/clover-ui.menu.desktop",2048),("/usr/share/applications/clover-ui.test.desktop",2048),("/usr/share/applications/clover-reset.factory.desktop",2048),("/usr/share/applications/clover-reset.menu.desktop",2048),("/etc/clover/LANGUAGE",128),("/proc/iomem",8192)] {
        let content=Data((path.hasSuffix(".desktop") ? "settings fixture":"display fixture").utf8)
        #expect(content.count<=max)
        bytes+=Data("FILE \(path) F \(content.count) \(BackupManifest.digest(content))\n".utf8)+content+Data([10])
    }
    return bytes+Data("SNES_STARTUP_DETAILS_END\n".utf8)
}

extension SNESStartupDetailsTests {
    @Test func actualDetailReaderRejectsInvalidFilesAndFailedProducers() throws {
        for fault in ["none","optional-absent","menu-absent","memory-oversize","required-absent","link","hardlink","oversize","nul","read","hash"] {
            let root=try testDirectory().resolvingSymlinksInPath();defer{try? FileManager.default.removeItem(at:root)}
            for (path,_) in SNESStartupDetails.paths {
                let target=root.appendingPathComponent((path.hasPrefix("/usr/") || path.hasPrefix("/etc/")) ? "root"+path : "system"+path)
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data((path.hasSuffix(".desktop") ? "settings fixture\n":"display fixture\n").utf8).write(to:target)
            }
            let settings=root.appendingPathComponent("root/usr/share/applications/clover-mcp.desktop")
            switch fault {
            case "optional-absent":try FileManager.default.removeItem(at:root.appendingPathComponent("system/sys/class/graphics/fb0/name"))
            case "menu-absent":try FileManager.default.removeItem(at:root.appendingPathComponent("root/usr/share/applications/clover-ui.menu.desktop"))
            case "memory-oversize":try Data(repeating:65,count:8193).write(to:root.appendingPathComponent("system/proc/iomem"))
            case "required-absent":try FileManager.default.removeItem(at:settings)
            case "link":try FileManager.default.removeItem(at:settings);try FileManager.default.createSymbolicLink(at:settings,withDestinationURL:root.appendingPathComponent("system/proc/cmdline"))
            case "hardlink":try FileManager.default.linkItem(at:settings,to:root.appendingPathComponent("linked"))
            case "oversize":try Data(repeating:65,count:4097).write(to:settings)
            case "nul":try Data([65,0,66]).write(to:settings)
            default:break
            }
            let wrapper="""
            #!/bin/bash
            cmd="$1"; shift
            case "$cmd" in
              wc) /usr/bin/wc "$@" | /usr/bin/xargs;;
              stat) exec /usr/bin/stat -f '%z:%l' "$3";;
              sha256sum) /usr/bin/shasum -a 256 "$@"; exit \(fault=="hash" ? 9:0);;
              head) /usr/bin/head "$@"; exit \(fault=="read" ? 9:0);;
              *) exec "$cmd" "$@";;
            esac
            """
            let bb=root.appendingPathComponent("busybox");try Data(wrapper.utf8).write(to:bb);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:bb.path)
            let common=SNESTemporaryMenuScripts.common
            let begin=try #require(common.range(of:"real_dir() {")),end=try #require(common.range(of:"require_usb() {"))
            let helper=SNESOriginalMenuScripts.startupDetails
                .replacingOccurrences(of:"source=\"$path\"",with:"source=\"\(root.path)/system$path\"")
                .replacingOccurrences(of:"/newroot",with:root.path+"/root")
            let script="set -eu\nB='\(bb.path)'\nfail(){ exit 9; }\n"+String(common[begin.lowerBound..<end.lowerBound])+helper+"\ncapture_startup_details\n"
            let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/bash");process.arguments=["-c",script]
            process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            try process.run();let bytes=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            let accepted=["none","optional-absent","menu-absent"].contains(fault)
            #expect((process.terminationStatus==0)==accepted,"fault=\(fault)")
            if accepted {_=try SNESStartupDetails(bytes)}
        }
    }
}


extension SNESStartupDetailsTests {
    @Test func captureFailuresCloseOnceWithoutLaunchOrReadyReports() async throws {
        guard let menu=try privateOriginalMenu() else{return}
        for fault in ["partial","checkpoint","none","capture-no-logs","cancel"] {
            let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
            let io=OriginalMenuFakeIO(menu:menu,fault:fault)
            await #expect(throws:(any Error).self){_=try await SNESOriginalMenuService(wait:{}).captureStartup(menu:menu,store:RecoveryBootSnapshotStore(root:root),io:io)}
            let events=await io.events
            #expect(!events.contains("launch") && !events.contains("report") && events.filter{$0=="disconnect"}.count==1)
        }
    }
}

extension SNESStartupDetailsTests {
    @Test func actualARMDetailsUseTheStrictNativeDecoder() throws {
        guard let path=ProcessInfo.processInfo.environment["SWIFTHAKCHI_ORIGINAL_MENU_ARM_FRAMES"] else{return}
        _=try SNESStartupDetails(Data(contentsOf:URL(fileURLWithPath:path).appendingPathComponent("details.frame")))
    }
}


extension SNESStartupDetailsTests {
    @Test func knownMenuDependenciesAndMemoryMapHaveFixedBoundedSlots() {
        let paths=SNESStartupDetails.paths.map(\.0)
        for path in ["/proc/iomem","/etc/clover/LANGUAGE","/usr/share/applications/clover-ui.menu.desktop","/usr/share/applications/clover-ui.test.desktop","/usr/share/applications/clover-reset.factory.desktop","/usr/share/applications/clover-reset.menu.desktop"] {
            #expect(paths.contains(path),"missing fixed diagnostic input \(path)")
        }
    }
}

extension SNESStartupDetailsTests {
    @Test func maximumFixedSettingsFitTheirFrameAndOriginalBaselineBudget() throws {
        var details=Data("SNES_STARTUP_DETAILS_BEGIN\n".utf8)
        for (path,maximum) in SNESStartupDetails.paths {
            let bytes=Data(repeating:65,count:maximum)
            details+=Data("FILE \(path) F \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8)+bytes+Data([10])
        }
        details+=Data("SNES_STARTUP_DETAILS_END\n".utf8)
        _=try SNESStartupDetails(details)
        let expected=originalMenuExpectationFixture(),challenge=UUID()
        let original=originalMenuReportFixture(expected:expected,challenge:challenge,state:.preMenu)
        let old=try SNESOriginalMenuReport(original,expected:expected,challenge:challenge,state:.preMenu).baseline
        for padding in [0,32768] {
            let extended=Data(old.dropLast("SNES_PRE_MENU_END\n".utf8.count))+Data(repeating:65,count:padding)+details+Data("SNES_PRE_MENU_END\n".utf8)
            let text=String(decoding:original,as:UTF8.self).replacingOccurrences(of:"BASELINE \(old.count) \(BackupManifest.digest(old))\n"+String(decoding:old,as:UTF8.self),with:"BASELINE \(extended.count) \(BackupManifest.digest(extended))\n"+String(decoding:extended,as:UTF8.self))
            if padding==0 {_=try SNESOriginalMenuReport(Data(text.utf8),expected:expected,challenge:challenge,state:.preMenu);#expect(extended.count<=32768)}
            else {#expect(throws:(any Error).self){_=try SNESOriginalMenuReport(Data(text.utf8),expected:expected,challenge:challenge,state:.preMenu)}}
        }
    }
}
