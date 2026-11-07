import Foundation
import ImageIO
import Testing
@testable import SwiftHakchiCore

struct SNESRAMCompatibilityMenuTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_MENU_SOURCE"] != nil,
                   "Requires the private original startup image and power trial files"))
    func buildsVolatileMenuAndRejectsChangedInputs() throws {
        let env = ProcessInfo.processInfo.environment
        let source = try Data(contentsOf: URL(fileURLWithPath: try #require(env["HC_MENU_SOURCE"])))
        let root = URL(fileURLWithPath: try #require(env["HC_MENU_PAYLOAD"]), isDirectory: true)
        let names = ["retroarch", "snes9x2010_libretro.so", "alien3.smc", "retroarch.cfg", "trial-start", "trial-owner", "autoconfig/Nintendo Clovercon - controller1.cfg"]
        let payload = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
        let report = try Data(contentsOf: URL(fileURLWithPath: try #require(env["HC_MENU_REPORT"])))
        let art = try Data(contentsOf: URL(fileURLWithPath: try #require(env["HC_MENU_ART"])))
        let candidate = try SNESRAMCompatibilityMenuBuilder.build(source: source, payload: payload, report: report, artwork: art)
        let repeated = try SNESRAMCompatibilityMenuBuilder.build(source: source, payload: payload, report: report, artwork: art)
        #expect(candidate.image == repeated.image)
        let result = try LegacyBootImageBuilder.inspect(candidate.image)
        #expect(result.kernel == (try LegacyBootImageBuilder.inspect(source).kernel))
        let files = Dictionary(uniqueKeysWithValues: result.archive.entries.map { ($0.name, $0.data) })
        let checked = result.archive.entries.filter { $0.fields[1] & 0xf000 == 0x8000 && $0.name != "probe/files.sha256" }
        let expectedManifest = Data(checked.sorted { $0.name < $1.name }.map { BackupManifest.digest($0.data) + "  /" + $0.name + "\n" }.joined().utf8)
        #expect(files["probe/files.sha256"] == expectedManifest)
        #expect(candidate.filesSHA256 == BackupManifest.digest(expectedManifest))
        let run = try #require(files["probe/run"].flatMap { String(data: $0, encoding: .utf8) })
        let trial = try #require(files["probe/compat/trial-start"].flatMap { String(data: $0, encoding: .utf8) })
        let desktop = try #require(files["probe/menu/CLV-U-ZZZZZ/CLV-U-ZZZZZ.desktop"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(run.contains("GamesFolder = /run/swifthakchi/menu"))
        #expect(run.contains("/usr/bin/clover-mcp --gui snes-usa"))
        #expect(!run.contains("chroot /newroot /run/swifthakchi/compat/trial-start"))
        let unmount = try #require(run.range(of: #""$B" umount "$config""#)?.lowerBound)
        let ready = try #require(run.range(of: "startup_stage ready")?.lowerBound)
        #expect(unmount < ready)
        #expect(desktop.contains("Exec=/run/swifthakchi/compat/trial-start"))
        #expect(trial.contains("trial-manager-entry"))
        #expect(trial.contains("trial-manager-observation"))
        #expect(trial.contains("/proc/$$/fd/"))
        #expect(!trial.contains("printf '%s\\n' \"$arg\""))
        // Execute the actual generated observation fragment with a local
        // BusyBox stand-in; no device or ROM is involved in this check.
        let begin = try #require(trial.range(of: "# Record only the three transition descriptor arguments")?.lowerBound)
        let end = try #require(trial.range(of: "stage=display-owner", range: begin..<trial.endIndex)?.lowerBound)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let busybox = temp.appendingPathComponent("busybox")
        try Data("#!/bin/sh\nexec \"$@\"\n".utf8).write(to: busybox)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: busybox.path)
        let output = temp.appendingPathComponent("observation")
        let status = temp.appendingPathComponent("status")
        try Data("PPid:\t41\n".utf8).write(to: status)
        let fragment = String(trial[begin..<end]).replacingOccurrences(of: "/run/swifthakchi/trial-manager-observation", with: output.path)
            .replacingOccurrences(of: #""/proc/$$/status""#, with: "'\(status.path)'")
        let harness = "set -eu\nB='\(busybox.path)'\nset -- --wait-transition-fd 11 --sram-file /private/secret --finish-transition-fd invalid\n" + fragment
        let observer = Process()
        observer.executableURL = URL(fileURLWithPath: "/bin/sh")
        observer.arguments = ["-c", harness]
        observer.standardOutput = FileHandle.nullDevice
        observer.standardError = FileHandle.nullDevice
        try observer.run(); observer.waitUntilExit()
        #expect(observer.terminationStatus == 0)
        let observed = try String(contentsOf: output, encoding: .utf8)
        #expect(observed.contains("ARG wait 11 missing\n"))
        #expect(observed.contains("ARG finish - invalid\n"))
        #expect(!observed.contains("secret"))
        #expect(files["probe/menu/CLV-U-ZZZZZ/CLV-U-ZZZZZ.png"] == art)
        let smallData = try #require(files["probe/menu/CLV-U-ZZZZZ/CLV-U-ZZZZZ_small.png"])
        let smallSource = try #require(CGImageSourceCreateWithData(smallData as CFData, nil))
        let small = try #require(CGImageSourceCreateImageAtIndex(smallSource, 0, nil))
        #expect(small.width <= 40 && small.height <= 40)
        for script in [run, trial] {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-n", "-c", script]
            shell.standardOutput = FileHandle.nullDevice
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            shell.waitUntilExit()
            #expect(shell.terminationStatus == 0)
        }
        var tampered = payload; tampered["alien3.smc"] = Data([0])
        #expect(throws: (any Error).self) { try SNESRAMCompatibilityMenuBuilder.build(source: source, payload: tampered, report: report, artwork: art) }
        #expect(throws: (any Error).self) { try SNESRAMCompatibilityMenuBuilder.build(source: source, payload: payload, report: report, artwork: Data()) }
        #expect(throws: (any Error).self) { try SNESRAMCompatibilityMenuBuilder.build(source: source, payload: payload, report: report, artwork: Data([137,80,78,71,13,10,26,10])) }
    }
}
