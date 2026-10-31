import Foundation
import Testing
@testable import SwiftHakchi

struct SNESTemporaryMenuStartupTests {
    @Test func firstStartupWaitsForOwnedRequestAndRejectsWrongRelease() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("33333333-3333-3333-3333-333333333333\n".utf8).write(to: root.appendingPathComponent("nonce"))
        let script = SNESTemporaryMenuScripts.startupGate.replacingOccurrences(of: "/probe/", with: "./")
        let assets = try SNESTemporaryMenuScripts.assets(base: probeScriptFixture(), sourceFiles: "")
        let run = String(decoding: try #require(assets["probe/run"]), as: UTF8.self)
        let end = try #require(run.range(of: "test ! -e /probe/controller-load"))
        let prefix = String(run[..<end.lowerBound]).replacingOccurrences(of: "/probe/", with: root.path + "/")
        try Data((script + "\nrequire_files() { :; }\nrequire_ro_blocks() { :; }\nrequire_startup_base() { :; }\n").utf8).write(to: root.appendingPathComponent("common"))
        let shim = """
        #!/bin/sh
        case "$1" in
          cat) shift; exec /bin/cat "$@";;
          sleep) test ! -e drivers-started || exit 95; cp nonce host-ready;;
          *) exit 92;;
        esac
        """
        try Data(shim.utf8).write(to: root.appendingPathComponent("busybox"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("busybox").path)
        #expect(try runMenuShell(prefix + "\ntrap - EXIT\nprintf 'DRIVERS' > drivers-started\n", in: root) == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("host-ready").path))
        #expect(try Data(contentsOf: root.appendingPathComponent("drivers-started")) == Data("DRIVERS".utf8))
        try Data("wrong\n".utf8).write(to: root.appendingPathComponent("host-ready"))
        #expect(try runMenuShell("\(script)\nawait_start_request\n", in: root) == 47)
    }
    @Test func progressSurvivesFailureWithoutBecomingASuccessfulMenuReport() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("loading-drivers\nstarting-device-service\nfailed:device-service\n".utf8).write(to: root.appendingPathComponent("startup-stages"))
        try Data("failed:device-service\n".utf8).write(to: root.appendingPathComponent("status"))
        let script = (SNESTemporaryMenuScripts.startupFeedback + "\n" + SNESTemporaryMenuScripts.waitReady).replacingOccurrences(of: "/probe/", with: "./")
        let p = Process(), output = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.currentDirectoryURL = root
        p.arguments = ["-c", "set -eu\nB=bb\nbb() { op=\"$1\"; shift; case \"$op\" in cat) /bin/cat \"$@\";; awk) /usr/bin/awk \"$@\";; *) exit 92;; esac; }\nfail() { exit 47; }\n" + script + "\nwait_until_ready\nprintf 'SUCCESS'\n"]
        p.standardOutput = output; p.standardError = errors
        try p.run(); let stdout = output.fileHandleForReading.readDataToEndOfFile(); let stderr = errors.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect(p.terminationStatus == 47)
        #expect(stdout.isEmpty)
        #expect(String(decoding: stderr, as: UTF8.self) == "SNES_STARTUP_STAGE=loading-drivers\nSNES_STARTUP_STAGE=starting-device-service\nSNES_STARTUP_STAGE=failed:device-service\n")
    }
    @Test(arguments: ["normal", "source", "linked"])
    func startupReleaseIsOneShotAndRefusesFailedGuardsOrLinkedMarker(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let assets = try SNESTemporaryMenuScripts.assets(base: probeScriptFixture(), sourceFiles: "")
        let script = String(decoding: try #require(assets["probe/start"]), as: UTF8.self).replacingOccurrences(of: "/probe/", with: root.path + "/")
        try Data(script.utf8).write(to: root.appendingPathComponent("start"))
        let common = "release_menu_after_baseline() { :; }\nrequire_startup_base() { test '\(fault)' != source || exit 47; }\n"
        try Data(common.utf8).write(to: root.appendingPathComponent("common"))
        try Data("#!/bin/sh\ncase \"$1\" in cat) shift; exec /bin/cat \"$@\";; sh) shift; exec /bin/sh \"$@\";; *) exit 92;; esac\n".utf8).write(to: root.appendingPathComponent("busybox"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("busybox").path)
        try Data("33333333-3333-3333-3333-333333333333\n".utf8).write(to: root.appendingPathComponent("nonce"))
        try Data("waiting-for-host\n".utf8).write(to: root.appendingPathComponent("status"))
        try Data("#!/bin/sh\nprintf 'REPORT\\n' >> report-count\n".utf8).write(to: root.appendingPathComponent("report"))
        if fault == "linked" {
            try Data("keep\n".utf8).write(to: root.appendingPathComponent("outside"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("host-ready"), withDestinationURL: root.appendingPathComponent("outside"))
        }
        let status = try runMenuShell("/bin/sh ./start 44444444-4444-4444-4444-444444444444\n", in: root)
        #expect((status == 0) == (fault == "normal"))
        if fault == "normal" {
            #expect(try Data(contentsOf: root.appendingPathComponent("host-ready")) == Data(contentsOf: root.appendingPathComponent("nonce")))
            #expect(try runMenuShell("/bin/sh ./start 44444444-4444-4444-4444-444444444444\n", in: root) != 0)
            #expect(try String(contentsOf: root.appendingPathComponent("report-count"), encoding: .utf8) == "REPORT\n")
        } else {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("report-count").path))
            if fault == "source" { #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("host-ready").path)) }
            if fault == "linked" { #expect(try String(contentsOf: root.appendingPathComponent("outside"), encoding: .utf8) == "keep\n") }
        }
    }
    @Test func fixedStartupCommandHasNoCallerShellOrPath() {
        #expect(SNESTemporaryMenuStartRequest.command(for: menuChallenge) == "exec /probe/busybox sh /probe/start 44444444-4444-4444-4444-444444444444")
    }
}
