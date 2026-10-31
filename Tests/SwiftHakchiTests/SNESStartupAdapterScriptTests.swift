import Foundation
import Testing
@testable import SwiftHakchi

struct SNESStartupAdapterScriptTests {
    @Test(arguments: ["start", "stop", "restart", "reload", "invalid", "start-original-fails", "start-service-fails", "stop-service-fails"])
    func usbWrapperPreservesOriginalOrderingAndFallback(_ scenario: String) throws {
        let scripts = try SNESStartupAdapterScripts(binding: .init(sourceSnapshot:"SNES-US-Setup-11111111-1111-1111-1111-111111111111",setupManifestSHA256:String(repeating:"1",count:64),expectedHWID:String(repeating:"1",count:32)))
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path, log = root.appendingPathComponent("calls")
        func write(_ name: String, _ text: String) throws {
            let url = root.appendingPathComponent(name); try Data(text.utf8).write(to:url)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)
        }
        try write("busybox","#!/bin/sh\nexec \"$@\"\n")
        try write("original-usb","#!/bin/sh\nprintf 'original:%s\\n' \"$1\" >> '\(log.path)'\n" + (scenario == "start-original-fails" ? "exit 7\n" : "exit 0\n"))
        try write("service","#!/bin/sh\nprintf 'service:%s\\n' \"$1\" >> '\(log.path)'\n" + (scenario.contains("service-fails") ? "exit 8\n" : "exit 0\n"))
        let wrapper = root.appendingPathComponent("wrapper")
        try Data(scripts.usbWrapper.replacingOccurrences(of:"/mnt/swifthakchi",with:path).utf8).write(to:wrapper)
        let action = scenario.split(separator:"-").first.map(String.init)!
        let p = Process();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=[wrapper.path,action]
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit()
        let calls = (try? String(contentsOf:log,encoding:.utf8).split(separator:"\n").map(String.init)) ?? []
        let expected: [String]
        switch scenario {
        case "start": expected=["original:start","service:start"]
        case "stop", "stop-service-fails":expected=["service:stop","original:stop"]
        case "restart", "reload":expected=["service:stop","original:stop","original:start","service:start"]
        case "invalid":expected=[]
        case "start-original-fails":expected=["original:start"]
        default:expected=["original:start","service:start","service:stop","original:start"]
        }
        #expect(calls == expected)
        #expect((p.terminationStatus == 0) == !["invalid","start-original-fails"].contains(scenario))
    }
    @Test func scriptBindingsRejectTextAndAcceptIndependentOwners() throws {
        for owner in ["1","a"] {
            _ = try SNESStartupAdapterScripts(binding:.init(sourceSnapshot:"SNES-US-Setup-11111111-1111-1111-1111-111111111111",setupManifestSHA256:String(repeating:"1",count:64),expectedHWID:String(repeating:owner,count:32)))
        }
        #expect(throws:(any Error).self) { try SNESStartupAdapterScripts(binding:.init(sourceSnapshot:"bad;command",setupManifestSHA256:String(repeating:"1",count:64),expectedHWID:String(repeating:"1",count:32))) }
    }
}
