import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

private let supportNonce=UUID(uuidString:"11111111-1111-1111-1111-111111111111")!
private let supportContext=String(repeating:"a",count:64)
private let supportHWID="0123456789abcdef0123456789abcdef"
func compatibilitySupportFixture() -> Data {
    var result=Data("HAKCHI_SNES_COMPAT_SUPPORT_V1\nCHALLENGE=\(supportNonce.uuidString)\nCONTEXT=\(supportContext)\nHWID=\(supportHWID)\n".utf8)
    var pthread=runtimeELFFixture("daemon");pthread[16]=3;pthread[44]=2
    for (role,chain,data) in [
        ("loader","ld-linux-armhf.so.3>ld-2.23.so",runtimeELFFixture("loader")),
        ("libc","libc.so.6>libc-2.23.so",runtimeELFFixture("libc")),
        ("pthread","libpthread.so.0>libpthread-2.23.so",pthread)] {
        result.append(Data("LIB \(role) \(chain) \(data.count) \(BackupManifest.digest(data))\n".utf8));result.append(data);result.append(10)
    }
    for (role,text) in [("input","I: Bus=0019 Vendor=0001 Product=0001 Version=0100\nN: Name=\"Clovercon\"\nH: Handlers=event0\n"),
                        ("audio-cards"," 0 [sunxi]: sunxi - sunxi\n"),("audio-pcm","00-00: playback 1\n"),("fb-size","1280,720\n"),("fb-bpp","32\n")] {
        let data=Data(text.utf8);result.append(Data("TEXT \(role) \(data.count) \(BackupManifest.digest(data))\n".utf8));result.append(data);result.append(10)
    }
    result.append(Data("END\n".utf8));return result
}
struct SNESCompatibilitySupportTests {
    @Test func fixedSupportFrameKeepsMatchedLibrariesAndPassiveDeviceMetadata() throws {
        let frame=try SNESCompatibilitySupportFrame(compatibilitySupportFixture(),challenge:supportNonce,context:supportContext,hwid:supportHWID)
        #expect(frame.libraries.count==3)
        #expect(frame.libraries["libc"]==runtimeELFFixture("libc"))
        #expect(frame.metadata["fb-size"]==Data("1280,720\n".utf8))
        #expect(frame.metadata["input"]?.range(of:Data("Handlers=event0".utf8)) != nil)
    }
    @Test(arguments:["trailing","truncated","wrong-nonce","changed-payload","unknown-role","escape-chain","oversize"])
    func unboundOrDamagedSupportDataRefuses(_ fault:String) {
        var bytes=compatibilitySupportFixture()
        switch fault {
        case "trailing":bytes.append(0)
        case "truncated":bytes.removeLast()
        case "wrong-nonce":let range=bytes.range(of:Data(supportNonce.uuidString.utf8))!;bytes.replaceSubrange(range,with:Data(UUID().uuidString.utf8))
        case "changed-payload":bytes[400] ^= 1
        case "unknown-role":let range=bytes.range(of:Data("TEXT input".utf8))!;bytes.replaceSubrange(range,with:Data("TEXT other".utf8))
        case "escape-chain":let range=bytes.range(of:Data("ld-2.23.so".utf8))!;bytes.replaceSubrange(range,with:Data("../escape".utf8))
        default:bytes=Data(count:7*1024*1024)
        }
        #expect(throws:(any Error).self) { try SNESCompatibilitySupportFrame(bytes,challenge:supportNonce,context:supportContext,hwid:supportHWID) }
    }
    @Test func callerTextCannotBecomeAShellArgument() {
        for bad in ["' ; touch /tmp/bad",String(repeating:"a",count:65),"\n",String(repeating:"G",count:64)] {
            #expect(throws:(any Error).self) { try SNESCompatibilitySupportCommand.read(challenge:supportNonce,context:bad,hwid:supportHWID) }
        }
    }
}

struct SNESCompatibilitySupportCommandTests {
    @Test(arguments:["normal","initial-rootfs","writable-root","library-submount","library-link","escape-link","oversize-text","read-error","active-game","late-game","wrong-mcp","active-supervisor"])
    func actualCommandReadsOnlyFixedOriginalFiles(_ fault:String) throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let lib=root.appendingPathComponent("lib")
        for directory in [lib,root.appendingPathComponent("proc/bus/input"),root.appendingPathComponent("proc/asound"),root.appendingPathComponent("sys/class/graphics/fb0")] {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        }
        var pthread=runtimeELFFixture("daemon");pthread[16]=3;pthread[44]=2
        for (name,data) in [("ld-linux-armhf.so.3",runtimeELFFixture("loader")),("libc.so.6",runtimeELFFixture("libc")),("libpthread.so.0",pthread)] {
            try data.write(to:lib.appendingPathComponent(name))
        }
        for (name,text) in [("proc/bus/input/devices","N: Name=\"Clovercon\"\nH: Handlers=event0\n"),("proc/asound/cards","0: sunxi\n"),("proc/asound/pcm","00-00: playback 1\n"),("sys/class/graphics/fb0/virtual_size","1280,720\n"),("sys/class/graphics/fb0/bits_per_pixel","32\n")] {
            try Data(text.utf8).write(to:root.appendingPathComponent(name))
        }
        let fakeProcess=root.appendingPathComponent("proc/42")
        try FileManager.default.createDirectory(at:fakeProcess,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(atPath:fakeProcess.appendingPathComponent("exe").path,
            withDestinationPath:fault=="wrong-mcp" ? "/usr/bin/other" : "/usr/bin/clover-mcp")
        var mounts="/dev/root / squashfs ro 0 0\n"
        if fault=="initial-rootfs" {mounts="rootfs / rootfs rw 0 0\n"+mounts}
        if fault=="writable-root" {mounts="/dev/root / squashfs rw 0 0\n"}
        if fault=="library-submount" {mounts += "tmpfs \(lib.path)/libc.so.6 tmpfs rw 0 0\n"}
        if fault=="library-link" {
            let other=root.appendingPathComponent("other");try FileManager.default.moveItem(at:lib,to:other)
            try FileManager.default.createSymbolicLink(at:lib,withDestinationURL:other)
        }
        if fault=="escape-link" {
            try FileManager.default.removeItem(at:lib.appendingPathComponent("libc.so.6"))
            try FileManager.default.createSymbolicLink(atPath:lib.appendingPathComponent("libc.so.6").path,withDestinationPath:"../outside.so")
            try Data("not-an-original-library".utf8).write(to:root.appendingPathComponent("outside.so"))
        }
        if fault=="oversize-text" {try Data(repeating:65,count:65537).write(to:root.appendingPathComponent("proc/bus/input/devices"))}
        try Data(mounts.utf8).write(to:root.appendingPathComponent("proc/mounts"))
        // Translate only the Linux utility ABI to the Mac host; file reads, hashes,
        // mount/link guards, framing and parser below are the actual implementation.
        let shim=root.appendingPathComponent("busybox-shim")
        let failRead=fault=="read-error" ? "if [ \"$cmd\" = head ]; then case \"$*\" in */proc/bus/input/devices*) printf 'partial\\n'; exit 1;; esac; fi\n" : ""
        let gamePID=fault=="active-game" ? "printf '99\\n'; exit 0" : (fault=="late-game" ? "test -f '\(root.path)/late-game' && { printf '99\\n'; exit 0; }; exit 1" : "exit 1")
        let markLate=fault=="late-game" ? "if [ \"$cmd\" = head ]; then case \"$*\" in */proc/bus/input/devices*) : > '\(root.path)/late-game';; esac; fi\n" : ""
        let helper=Data(("#!/bin/sh\ncmd=\"$1\"; shift\n"+failRead+markLate+"case \"$cmd\" in pidof) case \"$1\" in clover-mcp) printf '42\\n';; canoe-shvc) "+gamePID+";; hc-snes-superv) "+(fault=="active-supervisor" ? "printf '99\\n'; exit 0" : "exit 1")+";; *) exit 1;; esac;; readlink) if [ \"$1\" = -f ]; then shift; fi; exec /usr/bin/readlink \"$@\";; sha256sum) exec /usr/bin/shasum -a 256 \"$@\";; stat) shift 2; exec /usr/bin/stat -f '%l:%u' \"$@\";; *) exec \"$cmd\" \"$@\";; esac\n").utf8)
        try helper.write(to:shim);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:shim.path)
        var command=try SNESCompatibilitySupportCommand.read(challenge:supportNonce,context:supportContext,hwid:supportHWID)
        command=command.replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:shim.path)
            .replacingOccurrences(of:"440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6",with:BackupManifest.digest(helper))
            .replacingOccurrences(of:"= 1:0",with:"= 1:\(getuid())")
            .replacingOccurrences(of:"/lib",with:lib.path)
            .replacingOccurrences(of:"/proc/",with:root.path+"/proc/")
            .replacingOccurrences(of:"/sys/",with:root.path+"/sys/")
        let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=["-c",command]
        process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
        try process.run();let output=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        if ["normal","initial-rootfs"].contains(fault) {
            #expect(process.terminationStatus==0)
            let frame=try SNESCompatibilitySupportFrame(output,challenge:supportNonce,context:supportContext,hwid:supportHWID)
            #expect(frame.libraries["pthread"]==pthread)
            #expect(frame.metadata["fb-bpp"]==Data("32\n".utf8))
        } else {#expect(process.terminationStatus != 0)}
    }
}

private actor CompatibilityReadFixture {
    let fault:String
    private(set) var reads=0
    init(_ fault:String){self.fault=fault}
    func read(_ nonce:UUID)throws->Data {
        reads += 1
        if fault=="cancel" {throw CancellationError()}
        var frame=compatibilitySupportFixture()
        let range=frame.range(of:Data(supportNonce.uuidString.utf8))!
        let value=(fault=="wrong-challenge" && reads==2) ? UUID() : nonce
        frame.replaceSubrange(range,with:Data(value.uuidString.utf8))
        if fault=="changed" && reads==2 {
            // A second valid frame with different passive metadata must still refuse.
            let old=Data("1280,720\n".utf8),new=Data("1280,721\n".utf8)
            frame.replaceSubrange(frame.range(of:old)!,with:new)
            frame.replaceSubrange(frame.range(of:Data(BackupManifest.digest(old).utf8))!,with:Data(BackupManifest.digest(new).utf8))
        }
        return frame
    }
}
struct SNESCompatibilitySupportCaptureTests {
    @Test(arguments:["normal","changed","wrong-challenge","cancel"])
    func readsTwiceWithFreshChallengesAndNeverAcceptsChangedData(_ fault:String) async throws {
        let source=CompatibilityReadFixture(fault)
        do {
            let capture=try await SNESCompatibilitySupportCapture.read(context:supportContext,hwid:supportHWID,
                validate:{try Task.checkCancellation()},read:{try await source.read($0)})
            #expect(fault=="normal")
            #expect(capture.challenges.count==2 && Set(capture.challenges).count==2)
            #expect(capture.frame.metadata["fb-size"]==Data("1280,720\n".utf8))
        } catch {#expect(fault != "normal")}
        #expect(await source.reads == (fault=="cancel" ? 1 : 2))
    }
    @Test func missingPrivateSessionCannotRunCompatibilityPreflight() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("CLV-U-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: dir.appendingPathComponent("game.sfc"))
        var game = Game(code: "CLV-U-ABCDE", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local); game.romPath = dir.path
        let source = try SNESLibraryROMSource.capture(directory: dir, filename: "game.sfc").0
        let request = try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: Data([7] + Array(repeating: 0, count: 15)), epoch: 4)
        let io = SNESContextSupportNeverIO(), session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: io)
        await #expect(throws: (any Error).self) { try await session.preflightCompatibility(request: request, helperSHA256: String(repeating: "a", count: 64)) }
        #expect(await io.events.isEmpty)
    }
    @Test func missingPrivateSessionCannotReadSupportData() async {
        let io=SNESContextSupportNeverIO(),session=SNESLibraryConnectionSession(attachment:SNESLibraryContextTests.device(),io:io)
        await #expect(throws:(any Error).self) {try await session.captureCompatibilitySupport()}
        #expect(await io.events.isEmpty)
    }
}
private actor SNESContextSupportNeverIO:SNESLibraryConnectionIO {
    private(set) var events:[String]=[]
    func compatibilitySupport(context:SNESLibraryContext,challenge:UUID)->Data {events.append("support");return Data()}
    func open()throws{throw SNESCompatibilitySupportFrame.failure()}
    func inventory()->[RecoveryProbeUSBDevice]{events.append("inventory");return []}
    func identity(challenge:UUID)->Data{Data()}
    func report(installation:SNESLibraryInstallation,challenge:UUID)->Data{events.append("report");return Data()}
    func libraryInventory(context:SNESLibraryContext,challenge:UUID)->Data{Data()}
    func librarySpace(context:SNESLibraryContext,selection:SNESLibraryInventory.Selection,challenge:UUID)->Data{Data()}
    func libraryChunk(context:SNESLibraryContext,file:SNESLibraryInventory.File,offset:Int,challenge:UUID)->Data{Data()}
    func disconnect(){}
}
