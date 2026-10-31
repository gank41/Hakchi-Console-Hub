import Foundation
import Testing
@testable import SwiftHakchi

/// Catches releasing MCP before a bounded pre-menu baseline can be returned, and
/// losing its first error output while awaiting the final (separate) report.
struct SNESTemporaryMenuCheckpointTests {
    @Test func baselineIsBoundedAndCannotOverwriteExistingOrLinkedEvidence() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let nonce = "33333333-3333-3333-3333-333333333333\n"
        try Data(nonce.utf8).write(to: root.appendingPathComponent("nonce"))
        for (name, bytes) in [("power", Data("0\n".utf8)), ("memory", Data("MemFree: 64000 kB\n".utf8)),
                              ("input", Data("N: Name=fixture-input\n".utf8)), ("kernel", Data(repeating: 75, count: 20000))] {
            try bytes.write(to: root.appendingPathComponent(name))
        }
        let script = SNESTemporaryMenuScripts.menuCheckpoint
            .replacingOccurrences(of: "/sys/devices/knob/power_switch", with: "./power")
            .replacingOccurrences(of: "/proc/meminfo", with: "./memory")
            .replacingOccurrences(of: "/proc/bus/input/devices", with: "./input")
            .replacingOccurrences(of: "/probe/", with: "./")
        let shim = """
        bb() { op="$1"; shift; case "$op" in
          dmesg) /bin/cat kernel;;
          head|tail|cat) "/usr/bin/$op" "$@";;
          *) exit 92;;
        esac; }
        """
        #expect(try runMenuShell(shim + "\n" + script + "\ncapture_menu_baseline\n", in: root) == 0)
        let saved = try Data(contentsOf: root.appendingPathComponent("menu-baseline"))
        let text = String(decoding: saved, as: UTF8.self)
        #expect(saved.count <= 16384)
        #expect(text.contains("POWER_SWITCH=0\n") && text.contains("MemFree: 64000 kB") && text.contains("fixture-input"))
        #expect(text.hasPrefix("SNES_PRE_MENU_BEGIN\n") && text.hasSuffix("\nSNES_PRE_MENU_END\n"))
        #expect(try runMenuShell(shim + "\n" + script + "\ncapture_menu_baseline\n", in: root) != 0)
        #expect(try Data(contentsOf: root.appendingPathComponent("menu-baseline")) == saved)
        try FileManager.default.removeItem(at: root.appendingPathComponent("menu-baseline"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("menu-baseline"), withDestinationURL: root.appendingPathComponent("memory"))
        #expect(try runMenuShell(shim + "\n" + script + "\ncapture_menu_baseline\n", in: root) != 0)
        #expect(try String(contentsOf: root.appendingPathComponent("memory"), encoding: .utf8) == "MemFree: 64000 kB\n")
    }

    @Test(arguments: ["normal", "linked", "oversized"])
    func initialRequestEmitsBaselineBeforeReleasingMenu(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = SNESTemporaryMenuScripts.menuCheckpoint.replacingOccurrences(of: "/probe/", with: "./")
        try Data("33333333-3333-3333-3333-333333333333\n".utf8).write(to: root.appendingPathComponent("nonce"))
        try Data("waiting-for-menu-host\n".utf8).write(to: root.appendingPathComponent("status"))
        try Data("waiting-for-host\nwaiting-for-menu-host\n".utf8).write(to: root.appendingPathComponent("startup-stages"))
        let baseline = fault == "oversized" ? Data(repeating: 75, count: 16385) : Data("SNES_PRE_MENU_BEGIN\nPOWER_SWITCH=0\nSNES_PRE_MENU_END\n".utf8)
        try baseline.write(to: root.appendingPathComponent("menu-baseline"))
        if fault == "linked" { try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("menu-host-ready"), withDestinationURL: root.appendingPathComponent("nonce")) }
        let p = Process(), output = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.currentDirectoryURL = root
        p.arguments = ["-c", """
        set -eu
        B=bb
        bb() { op="$1"; shift; case "$op" in
          cat) /bin/cat "$@";; awk) /usr/bin/awk "$@";; wc) /usr/bin/wc "$@";;
          *) exit 92;;
        esac; }
        fail() { exit 47; }
        require_runtime() { :; }
        \(SNESTemporaryMenuScripts.startupFeedback.replacingOccurrences(of: "/probe/", with: "./"))
        \(script)
        release_menu_after_baseline
        test "$(cat menu-host-ready)" = "$(cat nonce)"
        printf 'RELEASED'
        """]
        p.standardOutput = output; p.standardError = errors
        try p.run(); let stdout = output.fileHandleForReading.readDataToEndOfFile(); let stderr = errors.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect((p.terminationStatus == 0) == (fault == "normal"))
        if fault == "normal" {
            #expect(stdout == Data("RELEASED".utf8))
            #expect(stderr.range(of: baseline) != nil)
            #expect(try Data(contentsOf: root.appendingPathComponent("menu-host-ready")) == Data(contentsOf: root.appendingPathComponent("nonce")))
        } else {
            #expect(stdout.isEmpty)
            if fault == "oversized" { #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("menu-host-ready").path)) }
        }
    }

    @Test func earlyMenuErrorIsReturnedOnStderrWithoutAcceptingAReport() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("failed:menu-exited\n".utf8).write(to: root.appendingPathComponent("status"))
        try Data("starting-menu\nfailed:menu-exited\n".utf8).write(to: root.appendingPathComponent("startup-stages"))
        try Data("fixture: graphics initialization failed\n".utf8).write(to: root.appendingPathComponent("menu.log"))
        let p = Process(), output = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.currentDirectoryURL = root
        p.arguments = ["-c", """
        set -eu
        B=bb
        bb() { op="$1"; shift; case "$op" in
          cat) /bin/cat "$@";; awk) /usr/bin/awk "$@";; wc) /usr/bin/wc "$@";; dd) /bin/dd "$@";;
          *) exit 92;;
        esac; }
        fail() { exit 47; }
        \(SNESTemporaryMenuScripts.startupFeedback.replacingOccurrences(of: "/probe/", with: "./"))
        \(SNESTemporaryMenuScripts.waitReady.replacingOccurrences(of: "/probe/", with: "./"))
        wait_until_ready
        printf SUCCESS
        """]
        p.standardOutput = output; p.standardError = errors
        try p.run(); let stdout = output.fileHandleForReading.readDataToEndOfFile(); let stderr = errors.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect(p.terminationStatus == 47 && stdout.isEmpty)
        #expect(String(decoding: stderr, as: UTF8.self).contains("fixture: graphics initialization failed\n"))
    }
}

extension SNESTemporaryMenuCheckpointTests {
    @Test func generatedInitialRequestOwnsBothRAMGates() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let assets = try SNESTemporaryMenuScripts.assets(base: probeScriptFixture(), sourceFiles: "")
        let start = String(decoding: try #require(assets["probe/start"]), as: UTF8.self).replacingOccurrences(of: "/probe/", with: root.path + "/")
        try Data(start.utf8).write(to: root.appendingPathComponent("start"))
        let common = (SNESTemporaryMenuScripts.startupFeedback + "\n" + SNESTemporaryMenuScripts.menuCheckpoint)
            .replacingOccurrences(of: "/probe/", with: root.path + "/") + "\nrequire_startup_base() { :; }\nrequire_runtime() { :; }\n"
        try Data(common.utf8).write(to: root.appendingPathComponent("common"))
        let shim = """
        #!/bin/sh
        op="$1"; shift
        case "$op" in
          cat) exec /bin/cat "$@";; awk) exec /usr/bin/awk "$@";; wc) exec /usr/bin/wc "$@";;
          sleep) exec /bin/sleep 0.02;; sh) exec /bin/sh "$@";; *) exit 92;;
        esac
        """
        try Data(shim.utf8).write(to: root.appendingPathComponent("busybox"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("busybox").path)
        try Data("33333333-3333-3333-3333-333333333333\n".utf8).write(to: root.appendingPathComponent("nonce"))
        try Data("waiting-for-host\n".utf8).write(to: root.appendingPathComponent("status"))
        try Data("waiting-for-host\n".utf8).write(to: root.appendingPathComponent("startup-stages"))
        try Data("#!/bin/sh\ntest -f menu-host-ready || exit 48\nprintf REPORT\n".utf8).write(to: root.appendingPathComponent("report"))
        let p = Process(), output = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.currentDirectoryURL = root
        p.arguments = ["-c", """
        set -eu
        (
          count=0
          while test ! -f host-ready; do count=$((count+1)); test "$count" -lt 100 || exit 49; /bin/sleep 0.01; done
          printf 'SNES_PRE_MENU_BEGIN\\nPOWER_SWITCH=0\\nSNES_PRE_MENU_END\\n' > menu-baseline
          printf 'waiting-for-menu-host\\n' >> startup-stages
          printf 'waiting-for-menu-host\\n' > status
        ) &
        worker=$!
        /bin/sh ./start 44444444-4444-4444-4444-444444444444
        wait "$worker"
        """]
        p.standardOutput = output; p.standardError = errors
        try p.run(); let stdout = output.fileHandleForReading.readDataToEndOfFile(); let stderr = errors.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect(p.terminationStatus == 0 && stdout == Data("REPORT".utf8))
        #expect(String(decoding: stderr, as: UTF8.self).contains("SNES_PRE_MENU_BEGIN\nPOWER_SWITCH=0\nSNES_PRE_MENU_END\n"))
        #expect(try Data(contentsOf: root.appendingPathComponent("host-ready")) == Data(contentsOf: root.appendingPathComponent("menu-host-ready")))
    }

    @Test func workerDoesNotLaunchWithWrongSecondNonce() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("33333333-3333-3333-3333-333333333333\n".utf8).write(to: root.appendingPathComponent("nonce"))
        try Data("wrong\n".utf8).write(to: root.appendingPathComponent("menu-host-ready"))
        let helper = (SNESTemporaryMenuScripts.startupGate + "\n" + SNESTemporaryMenuScripts.menuCheckpoint).replacingOccurrences(of: "/probe/", with: "./")
        #expect(try runMenuShell(helper + "\nawait_menu_request\nprintf bad > menu-started\n", in: root) == 47)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("menu-started").path))
    }

    @Test func menuOutputIsIncrementalAndCannotExceedItsTotalBudget() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 127, count: 12000).write(to: root.appendingPathComponent("menu.log"))
        let p = Process(), output = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.currentDirectoryURL = root
        p.arguments = ["-c", """
        set -eu
        B=bb
        bb() { op="$1"; shift; case "$op" in wc) /usr/bin/wc "$@";; dd) /bin/dd "$@";; *) exit 92;; esac; }
        fail() { exit 47; }
        \(SNESTemporaryMenuScripts.startupFeedback.replacingOccurrences(of: "/probe/", with: "./"))
        menu_emitted=0
        emit_menu_output
        emit_menu_output
        """]
        p.standardOutput = output; p.standardError = errors
        try p.run(); let stdout = output.fileHandleForReading.readDataToEndOfFile(); let stderr = errors.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect(p.terminationStatus == 0 && stdout.isEmpty)
        #expect(stderr.filter { $0 == 127 }.count == 8192)
        #expect(stderr.count < 8250)
    }
}

extension SNESTemporaryMenuCheckpointTests {
    @Test func failedKernelReadCannotReachTheCompleteBaselineMarkerOrLaunch() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["memory", "input"] { try Data("fixture\n".utf8).write(to: root.appendingPathComponent(name)) }
        let helper = SNESTemporaryMenuScripts.menuCheckpoint
            .replacingOccurrences(of: "/sys/devices/knob/power_switch", with: "./missing-power")
            .replacingOccurrences(of: "/proc/meminfo", with: "./memory")
            .replacingOccurrences(of: "/proc/bus/input/devices", with: "./input")
            .replacingOccurrences(of: "/probe/", with: "./")
        let command = """
        bb() { op="$1"; shift; case "$op" in
          head|tail) "/usr/bin/$op" "$@";;
          dmesg) exit 23;; *) exit 92;;
        esac; }
        \(helper)
        capture_menu_baseline
        printf bad > menu-started
        """
        #expect(try runMenuShell(command, in: root) == 47)
        let partial = try String(contentsOf: root.appendingPathComponent("menu-baseline"), encoding: .utf8)
        #expect(!partial.contains("SNES_PRE_MENU_END"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("menu-started").path))
    }
}
