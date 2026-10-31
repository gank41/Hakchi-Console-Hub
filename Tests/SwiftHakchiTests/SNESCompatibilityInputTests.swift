import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

private let inputContext=String(repeating:"a",count:64)
private let inputHWID="0123456789abcdef0123456789abcdef"
private func inputEvent(_ type:UInt16,_ code:UInt16,_ value:UInt32)->Data {
    var out=Data(repeating:0,count:8)
    for x in [UInt32(type)|UInt32(code)<<16,value] {for shift in stride(from:0,to:32,by:8) {out.append(UInt8(truncatingIfNeeded:x>>shift))}}
    return out
}
private func inputFrame(_ nonce:UUID,events:Data,path:String="/dev/input/event3")->Data {
    Data("HAKCHI_SNES_RESET_INPUT_V1\nCHALLENGE=\(nonce.uuidString)\nCONTEXT=\(inputContext)\nHWID=\(inputHWID)\nDEVICE=\(path)\nEVENTS=\(events.map{String(format:"%02x",$0)}.joined())\nEND\n".utf8)
}
struct SNESCompatibilityInputTests {
    @Test func onlyObservedPressAndReleaseCanIdentifyReset() throws {
        let n=UUID(),events=inputEvent(1,102,1)+inputEvent(0,0,0)+inputEvent(1,102,0)+inputEvent(0,0,0)
        let frame=try SNESCompatibilityInputFrame(inputFrame(n,events:events),challenge:n,context:inputContext,hwid:inputHWID)
        #expect(frame.device=="/dev/input/event3")
        #expect(frame.resetKey==102)
        let empty=try SNESCompatibilityInputFrame(inputFrame(n,events:Data()),challenge:n,context:inputContext,hwid:inputHWID)
        #expect(empty.resetKey==nil)
        let mixed=try SNESCompatibilityInputFrame(inputFrame(n,events:events+inputEvent(1,28,1)),challenge:n,context:inputContext,hwid:inputHWID)
        #expect(mixed.resetKey==nil)
        let reversed=try SNESCompatibilityInputFrame(inputFrame(n,events:inputEvent(1,102,0)+inputEvent(1,102,1)),challenge:n,context:inputContext,hwid:inputHWID)
        #expect(reversed.resetKey==nil)

    }
    @Test(arguments:["nonce","path","partial","oversize","type","trailing"])
    func unboundOrMalformedEventsRefuse(_ fault:String) {
        let n=UUID();var events=inputEvent(1,102,1),path="/dev/input/event3"
        if fault=="path" {path="/dev/input/../event3"}
        if fault=="partial" {events.append(0)}
        if fault=="oversize" {events=Data(count:528)}
        if fault=="type" {events=inputEvent(31,102,1)}
        var bytes=inputFrame(fault=="nonce" ? UUID():n,events:events,path:path)
        if fault=="trailing" {bytes.append(0)}
        #expect(throws:(any Error).self){try SNESCompatibilityInputFrame(bytes,challenge:n,context:inputContext,hwid:inputHWID)}
    }
    @Test func readerIsFixedAndDoesNotGrabOrWriteInputDevices() throws {
        let command=try SNESCompatibilityInputCommand.read(challenge:UUID(),context:inputContext,hwid:inputHWID)
        #expect(command.contains("sunxi-keyboard"))
        #expect(command.contains("count=16"))
        #expect(command.contains("timeout 60"))
        #expect(!command.contains("EVIOCGRAB"))
        #expect(!command.contains("of=/dev/input"))
    }
}

struct SNESCompatibilityInputCommandTests {
    @Test(arguments:["new","old","time-limit","game","duplicate-device","no-timeout","read-error","power","power-game","power-duplicate-device","power-read-error"])
    func actualReaderIsBoundedAndRefusesUnverifiedDevices(_ fault:String) throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let fm=FileManager.default
        for name in ["proc/42","sys/event3/device","sys/event4/device"] {try fm.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)}
        try Data("/dev/root / squashfs ro 0 0\n".utf8).write(to:root.appendingPathComponent("proc/mounts"))
        try fm.createSymbolicLink(atPath:root.appendingPathComponent("proc/42/exe").path,withDestinationPath:"/usr/bin/clover-mcp")
        try Data((fault.hasPrefix("power") ? "sunxi-knob\n":"sunxi-keyboard\n").utf8).write(to:root.appendingPathComponent("sys/event3/device/name"))
        if fault=="duplicate-device" || fault=="power-duplicate-device" {try Data((fault.hasPrefix("power") ? "sunxi-knob\n":"sunxi-keyboard\n").utf8).write(to:root.appendingPathComponent("sys/event4/device/name"))}
        let events=fault.hasPrefix("power") ? inputEvent(1,116,1) : inputEvent(1,102,1)+inputEvent(0,0,0)+inputEvent(1,102,0)+inputEvent(0,0,0)
        let dataPath=root.appendingPathComponent("events");try events.write(to:dataPath)
        let help=fault=="old" ? "Usage: timeout [-t SECS] PROG ARGS":fault=="no-timeout" ? "unknown applet":"Usage: timeout SECS PROG ARGS"
        let game=(fault=="game" || fault=="power-game") ? "echo 99":"exit 1"
        let helper=Data("""
        #!/bin/sh
        cmd="$1";shift
        case "$cmd" in
        pidof) case "$1" in clover-mcp) echo 42;;canoe-shvc) \(game);;*) exit 1;;esac;;
        readlink) if [ "$1" = -f ];then shift;fi;exec /usr/bin/readlink "$@";;
        stat) if [ "$2" = '%u' ];then echo 0;else echo 1:0;fi;;
        sha256sum) exec /usr/bin/shasum -a 256 "$@";;
        timeout) if [ "$1" = --help ];then echo '\(help)';exit 0;fi
          if [ "$1" = -t ];then shift;fi
          [ "$1" = \(fault.hasPrefix("power") ? "180":"60") ] || exit 88;shift
          \(fault=="time-limit" ? "\"$@\";exit 124":"exec \"$@\"");;
        dd) \((fault=="read-error" || fault=="power-read-error") ? "exit 1":"exec /bin/cat '\(dataPath.path)'");;
        *) exec "$cmd" "$@";;esac
        """.utf8)
        let shim=root.appendingPathComponent("busybox");try helper.write(to:shim);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:shim.path)
        let n=UUID();var script=try (fault.hasPrefix("power") ? SNESPowerInputCommand.read(challenge:n,context:inputContext,hwid:inputHWID) : SNESCompatibilityInputCommand.read(challenge:n,context:inputContext,hwid:inputHWID))
        script=script.replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:shim.path)
            .replacingOccurrences(of:"440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6",with:SwiftHakchiCore.BackupManifest.digest(helper))
            .replacingOccurrences(of:"/proc/",with:root.path+"/proc/")
            .replacingOccurrences(of:"/sys/class/input/",with:root.path+"/sys/")
            .replacingOccurrences(of:"test -c \"$input_device\"",with:"test \"$input_device\" = /dev/input/event3")
            .replacingOccurrences(of:"exec 8<\"$input_device\"",with:"exec 8<\"\(dataPath.path)\"")
        let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:"/bin/bash");task.arguments=["-c",script]
        task.standardOutput=pipe;task.standardError=FileHandle.nullDevice;try task.run()
        let raw=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
        if fault=="power" {
            #expect(task.terminationStatus==0)
            let result=try SNESPowerInputFrame(raw,challenge:n,context:inputContext,hwid:inputHWID)
            #expect(result.eventCode==116 && result.eventValue==1)
        } else if ["new","old","time-limit"].contains(fault) {
            #expect(task.terminationStatus==0)
            let result=try SNESCompatibilityInputFrame(raw,challenge:n,context:inputContext,hwid:inputHWID)
            #expect(result.resetKey==102)
        } else {#expect(task.terminationStatus != 0)}
    }
}

struct SNESCompatibilityInputDiagnosticTests {
    @Test func publishesOnlyValidatedEvidenceAfterClosedCollection() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let device=SNESLibraryContextTests.device()
        let n=UUID(),events=inputEvent(1,102,1)+inputEvent(1,102,0)
        let result=try await SNESCompatibilityInputDiagnostic.runIfPresent(["--capture-native-snes-reset-input",root.path,root.path],checkHost:{},inventory:{[device]},collect:{d,_ in
            .init(raw:inputFrame(n,events:events),challenge:n,context:inputContext,hwid:inputHWID,attachment:d,
                  reports:[Data("before".utf8),Data("after".utf8)],reportChallenges:[UUID(),UUID()])
        })
        let json=try JSONSerialization.jsonObject(with:Data(try #require(result).utf8)) as! [String:Any]
        let folder=URL(fileURLWithPath:try #require(json["directory"] as? String))
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("manifest.json"))) as! [String:Any]
        #expect(manifest["consoleFilesWritten"] as? Bool==false)
        #expect(manifest["resetKey"] as? Int==102)
        #expect(manifest["runtimeEligibility"] as? Bool==false)
        #expect(try Data(contentsOf:folder.appendingPathComponent("input.frame"))==inputFrame(n,events:events))
    }
}

struct SNESCompatibilityInputRefusalTests {
    @Test(arguments:["cancel","frame","attachment"])
    func incompleteCollectionNeverPublishesEvidence(_ fault:String) async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let device=SNESLibraryContextTests.device(),n=UUID()
        await #expect(throws:(any Error).self) {
            try await SNESCompatibilityInputDiagnostic.runIfPresent(["--capture-native-snes-reset-input",root.path,root.path],checkHost:{},inventory:{[device]},collect:{_,_ in
                if fault=="cancel" {throw CancellationError()}
                return .init(raw:inputFrame(fault=="frame" ? UUID():n,events:Data()),challenge:n,context:inputContext,hwid:inputHWID,
                    attachment:fault=="attachment" ? SNESLibraryContextTests.device(id:45):device,reports:[Data([1]),Data([2])],reportChallenges:[UUID(),UUID()])
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    @Test func malformedRequestCannotOpenUSB() async {
        await #expect(throws:(any Error).self) {
            try await SNESCompatibilityInputDiagnostic.runIfPresent(["--capture-native-snes-reset-input","relative","/tmp"],
                checkHost:{Issue.record("unexpected host access")},inventory:{Issue.record("unexpected USB access");return []},collect:{_,_ in throw CancellationError()})
        }
    }
}

struct SNESPowerInputCaptureTests {
    @Test func powerCaptureRequiresSingleBoundKeyEvent() throws {
        let n=UUID()
        let valid=powerFrame(n,event:inputEvent(1,116,1))
        let frame=try SNESPowerInputFrame(valid,challenge:n,context:inputContext,hwid:inputHWID)
        #expect(frame.device=="/dev/input/event2")
        #expect(frame.eventType==1 && frame.eventCode==116 && frame.eventValue==1)
        #expect(throws:(any Error).self){try SNESPowerInputFrame(powerFrame(n,event:Data()),challenge:n,context:inputContext,hwid:inputHWID)}
        #expect(throws:(any Error).self){try SNESPowerInputFrame(powerFrame(n,event:inputEvent(0,0,0)),challenge:n,context:inputContext,hwid:inputHWID)}
        #expect(throws:(any Error).self){try SNESPowerInputFrame(powerFrame(n,event:inputEvent(1,116,3)),challenge:n,context:inputContext,hwid:inputHWID)}
        #expect(throws:(any Error).self){try SNESPowerInputFrame(powerFrame(UUID(),event:inputEvent(1,116,1)),challenge:n,context:inputContext,hwid:inputHWID)}
        #expect(throws:(any Error).self){try SNESPowerInputFrame(powerFrame(n,event:inputEvent(1,116,1)+inputEvent(1,116,0)),challenge:n,context:inputContext,hwid:inputHWID)}
    }
    @Test func readOnlyIndexDoesNotChangeDirectoryPermissions() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
        #expect(throws:(any Error).self){try SNESLibraryInstallationIndex.existingPrivateRoot(root)}
        let attrs=try FileManager.default.attributesOfItem(atPath:root.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        #expect(try SNESLibraryInstallationIndex.existingPrivateRoot(root)==root)
    }
    @Test func acceptsOnlyTheExpectedReadyMessageOnSuccessfulResponse() throws {
        let n=UUID(),raw=powerFrame(n,event:inputEvent(1,116,0)),marker="HC_POWER_READER_READY_\(n.uuidString)\n"
        let ok=SSHResult(stdout:"",stderr:marker,stdoutData:raw,exitCode:0)
        #expect(try SNESPowerInputCommand.checkedResponse(ok,challenge:n)==raw)
        for result in [SSHResult(stdout:"",stderr:marker+"error\n",stdoutData:raw,exitCode:0),
                       SSHResult(stdout:"",stderr:"",stdoutData:raw,exitCode:0),
                       SSHResult(stdout:"",stderr:marker,stdoutData:raw,exitCode:1)] {
            #expect(throws:(any Error).self){try SNESPowerInputCommand.checkedResponse(result,challenge:n)}
        }
    }
    @Test func readinessRequiresTheCompleteMatchingMarker() {
        let n=UUID();let marker="HC_POWER_READER_READY_\(n.uuidString)\n"
        #expect(!SNESPowerInputCommand.hasReadyMarker(Data(marker.dropLast().utf8),challenge:n))
        #expect(!SNESPowerInputCommand.hasReadyMarker(Data(marker.utf8),challenge:UUID()))
        #expect(SNESPowerInputCommand.hasReadyMarker(Data(marker.utf8),challenge:n))
    }
    @Test func powerCommandReadsOnlyOneRecordAndDoesNotWrite() throws {
        let command=try SNESPowerInputCommand.read(challenge:UUID(),context:inputContext,hwid:inputHWID)
        #expect(command.contains("sunxi-knob"))
        #expect(command.contains("count=1"))
        #expect(command.contains("exec 8<\"$input_device\""))
        #expect(command.contains("HC_POWER_READER_READY"))
        #expect(command.contains("timeout 180"))
        #expect(!command.contains("EVIOCGRAB"))
        #expect(!command.contains("of=/dev/input"))
    }
}
private func powerFrame(_ nonce:UUID,event:Data)->Data {
    Data("HAKCHI_SNES_POWER_INPUT_V1\nCHALLENGE=\(nonce.uuidString)\nCONTEXT=\(inputContext)\nHWID=\(inputHWID)\nDEVICE=/dev/input/event2\nEVENTS=\(event.map{String(format:"%02x",$0)}.joined())\nEND\n".utf8)
}

struct SNESPowerInputDiagnosticTests {
    @Test func publishesBoundPowerEventOnlyAsEvidence() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let device=SNESLibraryContextTests.device(),n=UUID()
        let result=try await SNESPowerInputDiagnostic.runIfPresent(["--capture-native-snes-power-input",root.path,root.path],checkHost:{},inventory:{[device]},collect:{d,_ in
            .init(raw:powerFrame(n,event:inputEvent(1,116,1)),challenge:n,context:inputContext,hwid:inputHWID,attachment:d,
                  report:Data("before".utf8),reportChallenge:UUID())
        })
        let json=try JSONSerialization.jsonObject(with:Data(try #require(result).utf8)) as! [String:Any]
        let folder=URL(fileURLWithPath:try #require(json["directory"] as? String))
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("manifest.json"))) as! [String:Any]
        #expect(manifest["runtimeEligibility"] as? Bool==false)
        #expect(manifest["eventCode"] as? Int==116)
        #expect(manifest["eventValue"] as? Int==1)
    }
    @Test func malformedOrMismatchedCaptureDoesNotCreateEvidence() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let device=SNESLibraryContextTests.device(),n=UUID()
        await #expect(throws:(any Error).self){try await SNESPowerInputDiagnostic.runIfPresent(["--capture-native-snes-power-input",root.path,root.path],checkHost:{},inventory:{[device]},collect:{d,_ in
            .init(raw:powerFrame(UUID(),event:inputEvent(1,116,1)),challenge:n,context:inputContext,hwid:inputHWID,attachment:d,report:Data([1]),reportChallenge:UUID())
        })}
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
}
