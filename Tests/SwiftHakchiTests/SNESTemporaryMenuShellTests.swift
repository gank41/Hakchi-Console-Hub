import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func runMenuShell(_ text: String, in root: URL) throws -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.currentDirectoryURL = root
    p.arguments = ["-c", "set -eu\nB=bb\nbb() { case \"$1\" in awk) shift; /usr/bin/awk \"$@\";; cat) shift; /bin/cat \"$@\";; *) exit 92;; esac; }\nfail() { exit 47; }\n" + text]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit(); return p.terminationStatus
}
struct SNESTemporaryMenuShellTests {
    // The old kernel rejects bind sources on its initial MS_NOUSER rootfs.
    // Exercise the generated startup prefix with that mount boundary enforced.
    @Test(arguments: ["normal", "mount-failure", "copy-failure", "corrupt-copy", "existing-source"])
    func helpersMustMoveToCheckedBoundedRAMBeforeRootfsBindings(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = root.appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: probe.appendingPathComponent("rules"), withIntermediateDirectories: true)
        let shim = """
        #!/bin/sh
        set -eu
        root='\(root.path)'
        case "$1" in
          mount)
            shift
            if test "$1" = -t; then
              test '\(fault)' != mount-failure || exit 22
              test "$*" = "-t tmpfs -o size=16m,nosuid,nodev,mode=700 tmpfs $root/probe" || exit 90
              touch "$root/ordinary-ram-mounted"
            else
              test "$1" = --bind && test -f "$root/ordinary-ram-mounted" || exit 22
              printf 'BIND_OK\\n'
            fi;;
          cp)
            shift
            test '\(fault)' != copy-failure || exit 28
            /bin/cp "$@"
            if test '\(fault)' = corrupt-copy; then printf 'corrupt' > "$root/probe/rules/10-test.rules"; fi;;
          mkdir|mv) op="$1"; shift; "/bin/$op" "$@";;
          sha256sum) shift; /usr/bin/shasum -a 256 "$@";;
          *) exit 92;;
        esac
        """
        try Data(shim.utf8).write(to: probe.appendingPathComponent("busybox"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.appendingPathComponent("busybox").path)
        let assets = try SNESTemporaryMenuScripts.assets(base: probeScriptFixture(), sourceFiles: "")
        let common = SNESTemporaryMenuScripts.common.replacingOccurrences(of: "/probe", with: probe.path)
        try Data(common.utf8).write(to: probe.appendingPathComponent("common"))
        try Data("fixed audited rules\n".utf8).write(to: probe.appendingPathComponent("rules/10-test.rules"))
        var checks = ""
        for name in ["busybox", "common", "rules/10-test.rules"] {
            let file = probe.appendingPathComponent(name)
            checks += BackupManifest.digest(try Data(contentsOf: file)) + "  " + file.path + "\n"
        }
        try Data(checks.utf8).write(to: probe.appendingPathComponent("files.sha256"))
        let original = root.appendingPathComponent("original")
        try Data("original system file\n".utf8).write(to: original)
        try Data((BackupManifest.digest(try Data(contentsOf: original)) + "  " + original.path + "\n").utf8).write(to: probe.appendingPathComponent("source-files.sha256"))
        if fault == "existing-source" { try FileManager.default.createDirectory(at: root.appendingPathComponent("probe-source"), withIntermediateDirectories: false) }
        let early = String(decoding: try #require(assets["probe/early-init"]), as: UTF8.self)
        let begin = try #require(early.range(of: "trace original-file-checks"))
        let end = try #require(early.range(of: "trace usb-controller"))
        let prefix = String(early[begin.lowerBound..<end.lowerBound]).replacingOccurrences(of: "/probe", with: probe.path)
        let command = """
        set -eu
        B='\(probe.path)/busybox'
        fail() { exit 47; }
        trace() { :; }
        \(prefix)
        "$B" mount --bind '\(probe.path)/rules' '\(root.path)/target'
        """
        let p = Process(), output = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", command]
        p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect((p.terminationStatus == 0) == (fault == "normal"))
        #expect(bytes.isEmpty)
        let logged = (try? String(contentsOf: probe.appendingPathComponent("init.log"), encoding: .utf8)) ?? ""
        #expect(logged.contains("BIND_OK\n") == (fault == "normal"))
        #expect(try String(contentsOf: original, encoding: .utf8) == "original system file\n")
    }
    // Catches applying the stock kernel's model attribute to the pinned legacy
    // gadget, or accepting a changed descriptor / missing or redirected control.
    @Test(arguments: ["normal", "missing-hvc", "linked-hvc", "wrong-hvc", "wrong-version", "wrong-class", "wrong-product"])
    func legacyUSBSetupAndReadbackUseTheActualKernelAttributes(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gadget = root.appendingPathComponent("sys/devices/virtual/android_usb/android0")
        try FileManager.default.createDirectory(at: gadget.appendingPathComponent("f_clover"), withIntermediateDirectories: true)
        let role = root.appendingPathComponent("sys/devices/sunxi_usb/usb_role")
        try FileManager.default.createDirectory(at: role.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("0\n".utf8).write(to: role)
        for attr in ["enable", "idVendor", "idProduct", "bcdDevice", "bDeviceClass", "iProduct", "functions", "f_clover/hvc"] {
            if attr == "f_clover/hvc", fault == "missing-hvc" { continue }
            try Data("1\n".utf8).write(to: gadget.appendingPathComponent(attr))
        }
        if fault == "linked-hvc" {
            try FileManager.default.removeItem(at: gadget.appendingPathComponent("f_clover/hvc"))
            try Data("1\n".utf8).write(to: root.appendingPathComponent("redirect"))
            try FileManager.default.createSymbolicLink(at: gadget.appendingPathComponent("f_clover/hvc"), withDestinationURL: root.appendingPathComponent("redirect"))
        }
        let assets = try SNESTemporaryMenuScripts.assets(base: probeScriptFixture(), sourceFiles: "")
        let early = String(decoding: try #require(assets["probe/early-init"]), as: UTF8.self)
        let begin = try #require(early.range(of: "trace usb-controller"))
        let end = try #require(early.range(of: "trace diagnostic-service"))
        func fixturePaths(_ script: String) -> String {
            script.replacingOccurrences(of: "/sys/devices/", with: "./sys/devices/")
                .replacingOccurrences(of: "/dev/usb_clover", with: "/dev/null")
                .replacingOccurrences(of: ". /probe/common", with: ". ./common")
        }
        try Data(fixturePaths(SNESTemporaryMenuScripts.common).utf8).write(to: root.appendingPathComponent("common"))
        let setup = "trace() { :; }\n" + fixturePaths(String(early[begin.lowerBound..<end.lowerBound]))
        let status = try runMenuShell(setup, in: root)
        if ["missing-hvc", "linked-hvc"].contains(fault) {
            #expect(status == 47)
            #expect(try String(contentsOf: gadget.appendingPathComponent("enable"), encoding: .utf8) == "1\n")
            return
        }
        #expect(status == 0)
        guard status == 0 else { return }
        #expect(try String(contentsOf: gadget.appendingPathComponent("f_clover/hvc"), encoding: .utf8) == "0")
        #expect(!FileManager.default.fileExists(atPath: gadget.appendingPathComponent("f_clover/model").path))
        let changes = ["wrong-hvc": ("f_clover/hvc", "1"), "wrong-version": ("bcdDevice", "6a01"), "wrong-class": ("bDeviceClass", "255"), "wrong-product": ("iProduct", "Other device")]
        if let (attr, value) = changes[fault] { try Data(value.utf8).write(to: gadget.appendingPathComponent(attr)) }
        #expect(try runMenuShell(fixturePaths(SNESTemporaryMenuScripts.common) + "\nrequire_usb\n", in: root) == (fault == "normal" ? 0 : 47))
    }
    @Test(arguments: ["normal", "persistent", "unbounded", "writable-root", "duplicate", "missing"])
    func actualShellMountGuardRejectsPersistentAndUnboundedStorage(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var mounts = menuMounts()
        switch fault {
        case "persistent": mounts += "/dev/nandc /data ext4 rw 0 0\n"
        case "unbounded": mounts = mounts.replacingOccurrences(of: "size=8192k", with: "size=0")
        case "writable-root": mounts = mounts.replacingOccurrences(of: "squashfs ro,", with: "squashfs rw,")
        case "duplicate": mounts += "proc /proc proc rw 0 0\n"
        case "missing": mounts = mounts.replacingOccurrences(of: "tmpfs /newroot/run/swifthakchi tmpfs rw,nosuid,nodev,size=16384k,mode=700 0 0\n", with: "")
        default: break
        }
        try Data(mounts.utf8).write(to: root.appendingPathComponent("mounts"))
        let script = SNESTemporaryMenuScripts.common.replacingOccurrences(of: "/proc/mounts", with: "./mounts") + "\nrequire_mounts\n"
        #expect(try runMenuShell(script, in: root) == (fault == "normal" ? 0 : 47))
    }
    @Test(arguments: ["normal", "wrong-receipt", "missing-receipt", "linked-receipt", "force-taint", "missing-driver"])
    func actualShellDriverCheckRequiresSuccessfulFixedLoadAndUnforcedKernel(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["clovercon", "mali", "sunxi_keyboard", "sunxi_knob"] where !(fault == "missing-driver" && name == "mali") {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("modules/" + name), withIntermediateDirectories: true)
        }
        // The pinned driver has permission-zero parameters: there is no sysfs
        // parameters directory. Successful fixed-argument loading is the claim.
        let receipt = root.appendingPathComponent("controller-load")
        if fault != "missing-receipt" {
            try Data((fault == "wrong-receipt" ? "loaded-arguments:1,-1,2,-1;36;1;0;8;0\n" : "loaded-arguments:1,-1,2,-1;36;0;0;8;0\n").utf8).write(to: receipt)
        }
        if fault == "linked-receipt" {
            try FileManager.default.moveItem(at: receipt, to: root.appendingPathComponent("redirect"))
            try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: root.appendingPathComponent("redirect"))
        }
        try Data((fault == "force-taint" ? "2\n" : "4096\n").utf8).write(to: root.appendingPathComponent("taint"))
        let script = SNESTemporaryMenuScripts.common.replacingOccurrences(of: "/sys/module", with: "./modules")
            .replacingOccurrences(of: "/proc/sys/kernel/tainted", with: "./taint")
            .replacingOccurrences(of: "/probe/controller-load", with: "./controller-load") + "\nrequire_modules\n"
        #expect(try runMenuShell(script, in: root) == (fault == "normal" ? 0 : 47))
    }
    @Test func allGeneratedShellAssetsAreValidAndInitialFailureNeverStartsMenu() throws {
        let base = try probeScriptFixture(), assets = try SNESTemporaryMenuScripts.assets(base: base, sourceFiles: "")
        for name in ["probe/early-init", "probe/common", "probe/run", "probe/start", "probe/report", "probe/shutdown"] {
            let text = String(decoding: try #require(assets[name]), as: UTF8.self)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-n", "-c", text]
            try p.run(); p.waitUntilExit(); #expect(p.terminationStatus == 0)
        }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = root.appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let bb = probe.appendingPathComponent("busybox")
        try Data("#!/bin/sh\nexit 42\n".utf8).write(to: bb)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bb.path)
        let early = String(decoding: try #require(assets["probe/early-init"]), as: UTF8.self)
            .replacingOccurrences(of: "/probe", with: probe.path)
            .replacingOccurrences(of: "while :; do \"$B\" sleep 60; done", with: "exit 47")
        #expect(try runMenuShell(early, in: root) == 47)
        #expect(try String(contentsOf: probe.appendingPathComponent("status"), encoding: .utf8) == "failed:command\n")
        #expect(!FileManager.default.fileExists(atPath: probe.appendingPathComponent("menu.pid").path))
    }
}

struct SNESTemporaryMenuLivenessTests {
    @Test(arguments: ["S", "R", "Z", "X", "missing"])
    func exitedMenuCannotBeReportedAsWorking(state: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = SNESTemporaryMenuScripts.common
            .replacingOccurrences(of: "/probe/", with: "./")
            .replacingOccurrences(of: "/proc/", with: "./proc/")
        let setup = """
        mkdir -p "./proc/$$"
        printf '%s\\n' "$$" > menu.pid
        printf '%s\\n' "$$" > daemon.pid
        printf 'State: \\(state)\\n' > "./proc/$$/status"
        """.replacingOccurrences(of: "\\(state)", with: state)
        let command = script + "\nrequire_supervisor() { :; }\n" + setup + "\nrequire_alive\n"
        let status = try runMenuShell(command, in: root)
        #expect(status == (["S", "R"].contains(state) ? 0 : 47))
    }
    @Test(arguments: ["ready", "later", "failed", "timeout"])
    func startupWaitOnlyContinuesForAReadyMenu(state: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data((state == "ready" ? "ready\n" : (state == "failed" ? "failed:driver\n" : "starting\n")).utf8).write(to: root.appendingPathComponent("status"))
        let script = (SNESTemporaryMenuScripts.startupFeedback + "\n" + SNESTemporaryMenuScripts.waitReady).replacingOccurrences(of: "/probe/", with: "./")
        let command = """
        set -eu
        B=bb
        bb() { case "$1" in cat) /bin/cat "$2";; sleep) if test '\(state)' = later; then printf 'ready\\n' > status; fi;; *) exit 92;; esac; }
        fail() { exit 47; }
        \(script)
        wait_until_ready
        """
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.currentDirectoryURL = root
        p.arguments = ["-c",command]; p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == (["ready", "later"].contains(state) ? 0 : 47))
    }
}
