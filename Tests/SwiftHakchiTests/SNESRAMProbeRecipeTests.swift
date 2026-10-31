import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func probeScriptFixture() throws -> SNESRAMProbeScripts {
    try .init(binding: runtimeBindingFixture(), nonce: "22222222-2222-2222-2222-222222222222",
              loaderSHA256: String(repeating: "a", count: 64), libcSHA256: String(repeating: "b", count: 64),
              daemonSHA256: "8d36e4c280c7a8f5ce7a4639ffb103947dc4eee7f261230a0cda6b8092e2dfee")
}
func privateProbeFixture(root: URL) async throws -> PreparedSNESRAMProbe? {
    let env = ProcessInfo.processInfo.environment
    guard let setup = env["SWIFTHAKCHI_SNES_SETUP"], let kernelPath = env["SWIFTHAKCHI_SNES_KERNEL"],
          let hmodPath = env["SWIFTHAKCHI_SNES_CLOVERSHELL"], let busyboxPath = env["SWIFTHAKCHI_SNES_BUSYBOX"] else { return nil }
    let source = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: setup))
    let observation = try SNESBackupPolicy.observation(snesObservation().replacingOccurrences(of: runtimeBindingFixture().expectedHWID, with: source.expectedHWID))
    let report = SNESRuntimeMaterial(binding: source.runtimeBinding, frame: try SNESRuntimeFrame(runtimeFrameFixture()),
        before: probeFEL(), after: probeRNDIS(), observation: observation)
    let store = try RecoveryBootSnapshotStore(root: root)
    let runtimePath = try await store.saveSNESRuntime(report, source: source)
    let runtime = try SNESRuntimeMaterial.load(directory: runtimePath, source: source)
    let raw = try PinnedFELInputs.load()
    return try SNESRAMProbeRecipe.prepare(source: source, runtime: runtime,
        kernel: Data(contentsOf: URL(fileURLWithPath: kernelPath)), hmod: Data(contentsOf: URL(fileURLWithPath: hmodPath)),
        busybox: Data(contentsOf: URL(fileURLWithPath: busyboxPath)),
        recovery: .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage),
        nonce: "22222222-2222-2222-2222-222222222222")
}
struct SNESRAMProbeRecipeTests {
    @Test(arguments: ["0", "0\n", "00", "1", "224", "", "0 junk", "0\n1"])
    func usbDescriptorReadbackAcceptsOnlyCanonicalZeroClass(classValue: String) throws {
        let script = try probeScriptFixture().earlyInit
        let start = try #require(script.range(of: "test \"$(\"$B\" cat \"$g/idVendor\")\""))
        let end = try #require(script.range(of: "test -c /dev/usb_clover"))
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for (name, value) in ["idVendor": "1f3a\n", "idProduct": "efe8\n", "bcdDevice": "6a01\n",
                              "bDeviceClass": classValue, "iProduct": "Swift Hakchi SNES RAM Probe", "functions": "clover\n"] {
            try Data(value.utf8).write(to: root.appendingPathComponent(name))
        }
        let busybox = root.appendingPathComponent("busybox")
        try Data("#!/bin/sh\ntest \"$1\" = cat || exit 44\nexec /bin/cat \"$2\"\n".utf8).write(to: busybox)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: busybox.path)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.currentDirectoryURL = root
        process.arguments = ["-c", "set -eu\nB=./busybox\ng=.\nfail() { exit 77; }\n" + String(script[start.lowerBound..<end.lowerBound])]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == ((classValue == "0" || classValue == "0\n") ? 0 : 77))
    }
    @Test func temporaryConsoleTraceKeepsOriginalBootFlagsAndDoesNotExposeIdentity() throws {
        let command = " root=/dev/nandb decrypt ro console=ttyS0,115200 loglevel=4 consoleblank=0"
        let traced = try SNESRAMProbeRecipe.consoleTraceCommandLine(command)
        #expect(traced == "root=/dev/nandb decrypt ro console=ttyS0,115200 consoleblank=0 console=tty0 loglevel=7")
        for unsafe in [command + " rw", command + " rdinit=/other", command + " init=/other", command + " root=/other"] {
            #expect(throws: (any Error).self) { try SNESRAMProbeRecipe.consoleTraceCommandLine(unsafe) }
        }
        let text = try probeScriptFixture().earlyInit
        #expect(text.contains("/probe/stages.log"))
        #expect(text.contains("test -c /dev/tty0"))
        #expect(text.contains("trace \"Stopped at $stage ($1)\""))
        for label in ["file-checks", "command-line", "decrypting-original-system", "mounting-original-system", "console-identity", "mount-checks", "initial-report", "usb-controller", "usb-attributes", "usb-descriptors", "usb-enable", "usb-daemon"] {
            #expect(text.contains("trace " + label))
        }
        let begin = try #require(text.range(of: "trace() {")), end = try #require(text.range(of: "fail() {"))
        let function = text[begin.lowerBound..<end.lowerBound]
        #expect(!function.contains(runtimeBindingFixture().expectedHWID))
        #expect(!function.contains("key-file"))
    }
    @Test(arguments: ["normal", "missing", "symlink", "wrong-readback"])
    func controllerEntersDeviceModeOnlyAfterIdentityChecks(fault: String) throws {
        let script = try probeScriptFixture().earlyInit
        let start = try #require(script.range(of: "role=/sys/devices/sunxi_usb/usb_role"))
        let end = try #require(script.range(of: "g=/sys/devices/virtual/android_usb/android0"))
        let checkedIdentity = try #require(script.range(of: "|| fail identity"))
        let checkedMounts = try #require(script.range(of: "|| fail mounts"))
        #expect(start.lowerBound > checkedIdentity.upperBound && start.lowerBound > checkedMounts.upperBound)
        #expect(start.lowerBound < end.lowerBound)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let role = root.appendingPathComponent("role")
        if fault == "symlink" {
            try Data("1".utf8).write(to: root.appendingPathComponent("other"))
            try FileManager.default.createSymbolicLink(atPath: role.path, withDestinationPath: "other")
        } else if fault != "missing" { try Data("1".utf8).write(to: role) }
        let fake = root.appendingPathComponent("busybox")
        let fakeText = fault == "wrong-readback" ? "#!/bin/sh\nprintf 1\n" : "#!/bin/sh\ntest \"$1\" = cat || exit 44\nexec /bin/cat \"$2\"\n"
        try Data(fakeText.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let section = String(script[start.lowerBound..<end.lowerBound]).replacingOccurrences(of: "/sys/devices/sunxi_usb/usb_role", with: "./role")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.currentDirectoryURL = root
        process.arguments = ["-c", "set -eu\nB=./busybox\nfail() { exit 77; }\ntrace() { :; }\n" + section]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        if fault == "normal" { #expect(process.terminationStatus == 0); #expect(try String(contentsOf: role, encoding: .utf8) == "2") }
        else { #expect(process.terminationStatus == 77) }
        if fault == "missing" { #expect(!FileManager.default.fileExists(atPath: role.path)) }
        if fault == "symlink" { #expect(try String(contentsOf: root.appendingPathComponent("other"), encoding: .utf8) == "1") }
    }
    @Test func changedRuntimeIsRejectedBeforeNativeOpenAndFailedExportHasNoManifest() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let probe = try await privateProbeFixture(root: root) else { return }
        let failed = try RecoveryBootSnapshotStore(root: root, synchronize: { _ in -1 })
        await #expect(throws: (any Error).self) { try await failed.saveSNESProbe(probe) }
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let partial = children.filter { $0.lastPathComponent.hasPrefix("SNES-RAM-Probe-") }
        #expect(partial.count == 1)
        #expect(!FileManager.default.fileExists(atPath: partial[0].appendingPathComponent("manifest.json").path))
        let saved = try await RecoveryBootSnapshotStore(root: root).saveSNESProbe(probe)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: saved.appendingPathComponent("manifest.json"))) as? [String: Any])
        let runtime = URL(fileURLWithPath: try #require(manifest["runtimePath"] as? String))
        try Data("changed".utf8).write(to: runtime.appendingPathComponent("libc.bin"))
        #expect(throws: (any Error).self) { try probe.validateCurrent() }
        // Even a previously sealed value is checked again before the native session factory.
        let service = FELService(makeSession: { Issue.record("Stale runtime reached native open"); return IOKitFELSessionTransport() })
        await #expect(throws: (any Error).self) { try await service.memboot(probe: probe) }
    }
    @Test func earlyScriptsAreBoundedReadOnlyAndNeverEnterOldStartup() throws {
        let scripts = try probeScriptFixture()
        #expect(scripts.entryPoint == "#!/bin/sh\nexec /probe/busybox sh /probe/early-init\n")
        #expect(scripts.earlyInit.contains("--readonly"))
        #expect(scripts.earlyInit.contains("ro,noatime"))
        #expect(scripts.earlyInit.contains("dp-shvc"))
        #expect(scripts.earlyInit.contains("6a01"))
        #expect(scripts.earlyInit.contains("Swift Hakchi SNES RAM Probe"))
        #expect(scripts.earlyInit.contains("--inhibit-cache --inhibit-rpath '' --library-path /probe"))
        #expect(scripts.report.contains("SWIFTHAKCHI_SNES_RAM_REPORT_V1"))
        for script in [scripts.entryPoint, scripts.earlyInit, scripts.report] {
            for forbidden in ["/dev/nandc", "/var/lib", "switch_root", "/hakchi/", "burn_", "reboot", "mount -a", "source "] {
                #expect(script.contains(forbidden) == false)
            }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-n", "-c", script]
            try p.run(); p.waitUntilExit(); #expect(p.terminationStatus == 0)
        }
        #expect(throws: (any Error).self) { try SNESRAMProbeScripts(binding: runtimeBindingFixture(), nonce: "bad';reboot",
            loaderSHA256: "x", libcSHA256: "y", daemonSHA256: "z") }
    }
    @Test func initialCommandFailureWaitsWithoutFallbackOrUSBGadget() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = root.appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let fake = probe.appendingPathComponent("busybox")
        try Data("#!/bin/sh\nexit 42\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let text = try probeScriptFixture().earlyInit.replacingOccurrences(of: "/probe", with: probe.path)
            .replacingOccurrences(of: "while :; do \"$B\" sleep 60; done", with: "exit 77")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", text]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); #expect(p.terminationStatus == 77)
        let status = try String(contentsOf: probe.appendingPathComponent("status"), encoding: .utf8)
        #expect(status.contains("failed"))
        let stages = try String(contentsOf: probe.appendingPathComponent("stages.log"), encoding: .utf8)
        #expect(stages.contains("Stopped at virtual-filesystems (command)"))
        #expect(!stages.contains(runtimeBindingFixture().expectedHWID))
    }
    @Test func unavailableTraceOutputsCannotStopStartup() throws {
        let text = try probeScriptFixture().earlyInit
        let begin = try #require(text.range(of: "trace() {")), end = try #require(text.range(of: "fail() {"))
        let function = String(text[begin.lowerBound..<end.lowerBound])
            .replacingOccurrences(of: "test -c /dev/tty0", with: "test 1 = 1")
            .replacingOccurrences(of: "/dev/tty0", with: "./absent/tty")
            .replacingOccurrences(of: "/probe/stages.log", with: "./absent/stages.log")
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.currentDirectoryURL = root
        process.arguments = ["-c", "set -eu\n" + function + "\ntrace test-stage\nexit 0\n"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
    }
    @Test func privateRecipeIsSealedReproducibleAndRejectsChangedSavedImage() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let probe = try await privateProbeFixture(root: root) else { return }
        let contents = try LegacyBootImageBuilder.inspect(probe.image)
        let tracedCommand = String(decoding: contents.header[64..<576].prefix { $0 != 0 }, as: UTF8.self)
        #expect(tracedCommand.contains("console=tty0") && tracedCommand.contains("loglevel=7"))
        #expect(contents.archive.entries.contains { $0.name == "probe/busybox" })
        let entryPoint = try probeScriptFixture().entryPoint
        #expect(contents.archive.entries.first { $0.name == "init" }?.data == Data(entryPoint.utf8))
        #expect(probe.nonce == "22222222-2222-2222-2222-222222222222")
        try probe.validateCurrent()
        let directory = try await RecoveryBootSnapshotStore(root: root).saveSNESProbe(probe)
        let raw = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage)
        let loaded = try SNESRAMProbeRecipe.load(directory: directory, recovery: inputs)
        #expect(loaded.image == probe.image)
        let imagePath = directory.appendingPathComponent("probe.img")
        var changed = try Data(contentsOf: imagePath); changed[2048] ^= 1
        try changed.write(to: imagePath)
        #expect(throws: (any Error).self) { try SNESRAMProbeRecipe.load(directory: directory, recovery: inputs) }
    }
}
