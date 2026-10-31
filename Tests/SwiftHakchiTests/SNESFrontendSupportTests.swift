import Foundation
import Testing
import Darwin
import SwiftHakchiCore
@testable import SwiftHakchi

private let frontendContext = String(repeating: "a", count: 64)
private let frontendHWID = "0123456789abcdef0123456789abcdef"
func frontendSupportFixture(_ challenge: UUID, library: Data = runtimeELFFixture("libc"), badPath: Bool = false) -> Data {
    var bytes = Data("HAKCHI_SNES_FRONTEND_SUPPORT_V1\nCHALLENGE=\(challenge.uuidString)\nCONTEXT=\(frontendContext)\nHWID=\(frontendHWID)\n".utf8)
    for (role,_,_) in SNESFrontendSupportFrame.roles {
        if role == "math" {
            bytes.append(Data("LIB math /lib/libm.so.6>\(badPath ? "/tmp/libm-2.23.so" : "/lib/libm-2.23.so") \(library.count) \(BackupManifest.digest(library))\n".utf8))
            bytes.append(library); bytes.append(10)
        } else { bytes.append(Data("MISS \(role)\n".utf8)) }
    }
    bytes.append(Data("END\n".utf8)); return bytes
}
struct SNESFrontendSupportTests {
    @Test func boundedEvidenceDistinguishesOriginalFilesFromMissingDependencies() throws {
        let nonce=UUID(),bytes=frontendSupportFixture(nonce)
        let frame=try SNESFrontendSupportFrame(bytes,challenge:nonce,context:frontendContext,hwid:frontendHWID)
        #expect(frame.libraries["math"]==runtimeELFFixture("libc"))
        #expect(frame.missing.contains("egl"))
        #expect(frame.missing.count==11)
        #expect(frame.chains["math"]=="/lib/libm.so.6>/lib/libm-2.23.so")
    }
    @Test func originalVendorELFWithUnmarkedFloatABICanBeCapturedAsEvidence() throws {
        let nonce=UUID();var vendor=runtimeELFFixture("libc")
        vendor[36]=2;vendor[37]=0;vendor[38]=0;vendor[39]=5
        let frame=try SNESFrontendSupportFrame(frontendSupportFixture(nonce,library:vendor),challenge:nonce,context:frontendContext,hwid:frontendHWID)
        #expect(frame.libraries["math"]==vendor)
        // Evidence capture must not relax the separate execution-package boundary.
        var core=compatibilityELF()
        _ = try SNESCompatibilityELF(data:core)
        core[36]=2;core[37]=0;core[38]=0;core[39]=5
        #expect(throws:(any Error).self){try SNESCompatibilityELF(data:core)}
    }
    @Test(arguments:["wrong-nonce","trailing","hash","escape","role","huge"])
    func wrongBindingOrUnconfinedBytesCannotBecomeEvidence(_ fault:String) {
        let nonce=UUID();var bytes=frontendSupportFixture(nonce,badPath:fault=="escape")
        switch fault {
        case "wrong-nonce": bytes=frontendSupportFixture(UUID())
        case "trailing":bytes.append(0)
        case "hash":bytes[bytes.count-10] ^= 1
        case "role":bytes.replaceSubrange(bytes.range(of:Data("MISS rt".utf8))!,with:Data("MISS other".utf8))
        case "huge":bytes=Data(count:SNESFrontendSupportFrame.maximumBytes+1)
        default:break
        }
        #expect(throws:(any Error).self){try SNESFrontendSupportFrame(bytes,challenge:nonce,context:frontendContext,hwid:frontendHWID)}
    }
}

private actor FrontendReadSource {
    let fault:String
    private(set) var reads=0
    init(_ fault:String){self.fault=fault}
    func read(_ nonce:UUID)throws->Data {
        reads += 1
        if fault=="cancel" {throw CancellationError()}
        if fault=="changed" && reads==2 {
            var data=runtimeELFFixture("libc");data[data.count-1] ^= 1
            return frontendSupportFixture(nonce,library:data)
        }
        return frontendSupportFixture(fault=="nonce" && reads==2 ? UUID():nonce)
    }
}
struct SNESFrontendCaptureTests {
    @Test(arguments:["normal","changed","nonce","cancel"])
    func freshReadsMustAgreeWithoutRetry(_ fault:String) async throws {
        let source=FrontendReadSource(fault)
        do {
            let result=try await SNESFrontendSupportCapture.read(context:frontendContext,hwid:frontendHWID,
                validate:{try Task.checkCancellation()},read:{try await source.read($0)})
            #expect(fault=="normal")
            #expect(result.frames.count==2 && Set(result.challenges).count==2)
            #expect(result.frame.missing.contains("sdl"))
        } catch {#expect(fault != "normal")}
        #expect(await source.reads == (fault=="cancel" ? 1:2))
    }
}

struct SNESFrontendCommandTests {
    @Test(arguments:["normal","game","rw-root","usr-mount","escape","oversize","wrong-mcp"])
    func actualFixedReaderCannotEscapeOriginalLibraries(_ fault:String) throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let lib=root.appendingPathComponent("lib"),usr=root.appendingPathComponent("usr-lib")
        for dir in [lib,usr,root.appendingPathComponent("proc/42")] {try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)}
        let data=runtimeELFFixture("libc")
        try data.write(to:lib.appendingPathComponent("libm-2.23.so"))
        try FileManager.default.createSymbolicLink(atPath:lib.appendingPathComponent("libm.so.6").path,
            withDestinationPath:fault=="escape" ? "../../escape.so":"libm-2.23.so")
        if fault=="oversize" {
            let handle=try FileHandle(forWritingTo:lib.appendingPathComponent("libm-2.23.so"));try handle.truncate(atOffset:UInt64(SNESFrontendSupportFrame.maximumLibraryBytes+1));try handle.close()
        }
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("proc/42/exe").path,
            withDestinationPath:fault=="wrong-mcp" ? "/usr/bin/foreign":"/usr/bin/clover-mcp")
        var mounts="/dev/root / squashfs \(fault=="rw-root" ? "rw":"ro") 0 0\n"
        if fault=="usr-mount" {mounts += "tmpfs \(usr.path) tmpfs rw 0 0\n"}
        try Data(mounts.utf8).write(to:root.appendingPathComponent("proc/mounts"))
        let game=fault=="game" ? "printf '99\\n'":"exit 1"
        let helper=Data(("#!/bin/sh\ncmd=\"$1\"; shift\ncase \"$cmd\" in pidof) case \"$1\" in clover-mcp) printf '42\\n';; canoe-shvc) "+game+";; *) exit 1;; esac;; readlink) if [ \"$1\" = -f ]; then shift; fi; exec /usr/bin/readlink \"$@\";; sha256sum) exec /usr/bin/shasum -a 256 \"$@\";; stat) shift 2; exec /usr/bin/stat -f '%l:%u' \"$@\";; *) exec \"$cmd\" \"$@\";; esac\n").utf8)
        let shim=root.appendingPathComponent("busybox");try helper.write(to:shim);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:shim.path)
        let nonce=UUID()
        var command=try SNESFrontendSupportCommand.read(challenge:nonce,context:frontendContext,hwid:frontendHWID)
        command=command.replacingOccurrences(of:"/usr/lib",with:"__USRLIB__").replacingOccurrences(of:"/lib",with:"__LIB__")
            .replacingOccurrences(of:"__USRLIB__",with:usr.path).replacingOccurrences(of:"__LIB__",with:lib.path)
            .replacingOccurrences(of:"/proc/",with:root.path+"/proc/")
            .replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:shim.path)
            .replacingOccurrences(of:"440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6",with:BackupManifest.digest(helper))
            .replacingOccurrences(of:"= 1:0",with:"= 1:\(getuid())")
        let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:"/bin/sh");task.arguments=["-c",command]
        task.standardOutput=pipe;task.standardError=FileHandle.nullDevice
        try task.run();let raw=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
        if fault=="normal" {
            #expect(task.terminationStatus==0)
            // Payload is binary: replace only the path-bearing ASCII header.
            var frame=raw
            for (from,to) in [(usr.path,"/usr/lib"),(lib.path,"/lib")] {
                while let range=frame.range(of:Data(from.utf8)) {frame.replaceSubrange(range,with:Data(to.utf8))}
            }
            let result=try SNESFrontendSupportFrame(frame,challenge:nonce,context:frontendContext,hwid:frontendHWID)
            #expect(result.libraries["math"]==data)
            #expect(result.missing.count==11)
        } else {#expect(task.terminationStatus != 0)}
    }
}
