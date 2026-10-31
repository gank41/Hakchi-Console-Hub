import Foundation
import Testing
@testable import SwiftHakchiCore

struct HCTrialCapacityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_TRIAL_SOURCE_IMAGE"] != nil &&
                  ProcessInfo.processInfo.environment["HC_TRIAL_PAYLOAD"] != nil &&
                  ProcessInfo.processInfo.environment["HC_TRIAL_REPORT"] != nil,
                  "Requires a private startup image and trial payload for an offline capacity check"))
    func inspectOneGameTrialCapacity() throws {
        guard let imagePath = ProcessInfo.processInfo.environment["HC_TRIAL_SOURCE_IMAGE"],
              let packagePath = ProcessInfo.processInfo.environment["HC_TRIAL_PAYLOAD"],
              let reportPath = ProcessInfo.processInfo.environment["HC_TRIAL_REPORT"] else { return }
        let source = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        let trialRoot = URL(fileURLWithPath: packagePath, isDirectory: true)
        let names = ["retroarch", "snes9x2010_libretro.so", "alien3.smc", "retroarch.cfg", "autoconfig/Nintendo Clovercon - controller1.cfg", "trial-start"]
        let payload = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: trialRoot.appendingPathComponent($0))) })
        let report = try Data(contentsOf: URL(fileURLWithPath: reportPath))
        let prepared = try SNESAlienTrialImageBuilder.build(source: source, payload: payload, report: report)
        #expect(try LegacyBootImageBuilder.inspect(prepared.image).kernel == LegacyBootImageBuilder.inspect(source).kernel)
        var tampered = payload; tampered["alien3.smc"] = Data([0])
        #expect(throws: (any Error).self) { try SNESAlienTrialImageBuilder.build(source: source, payload: tampered, report: report) }
        #expect(throws: (any Error).self) { try SNESAlienTrialImageBuilder.build(source: source, payload: payload, report: Data()) }
        let original = try LegacyBootImageBuilder.inspect(source)
        guard let runEntry = original.archive.entries.first(where: { $0.name == "probe/run" }),
              let originalRun = String(data: runEntry.data, encoding: .utf8),
              originalRun.contains("insmod /probe/clvcon.ko module_params=1,195,2,194"),
              originalRun.contains("capture_menu_baseline\nawait_menu_request\n") else {
            throw RecoveryImageError.invalid("The input is not the matched SNES original-menu startup image.")
        }
        let originalFiles = Dictionary(uniqueKeysWithValues: original.archive.entries
            .filter { $0.fields[1] & 0xf000 == 0x8000 && $0.name != "probe/files.sha256" }
            .map { ($0.name, $0.data) })
        let expectedOriginalManifest = Data(originalFiles.keys.sorted().map {
            BackupManifest.digest(originalFiles[$0]!) + "  /" + $0 + "\n"
        }.joined().utf8)
        guard original.archive.entries.first(where: { $0.name == "probe/files.sha256" })?.data == expectedOriginalManifest else {
            throw RecoveryImageError.invalid("The original startup image failed its file-integrity check.")
        }
        let root = URL(fileURLWithPath: packagePath, isDirectory: true)
        var entries: [NewcEntry] = []
        func add(_ path: String, _ mode: UInt32, _ data: Data) {
            entries.append(NewcEntry(name: path, fields: [UInt32(62000 + entries.count), mode, 0, 0,
                mode & 0xf000 == 0x4000 ? 2 : 1, 0, UInt32(data.count), 0, 0, 0, 0,
                UInt32(path.utf8.count + 1), 0], data: data))
        }
        add("probe/compat", 0o40700, Data())
        add("probe/compat/autoconfig", 0o40700, Data())
        for (name, mode) in [("retroarch", UInt32(0o100700)), ("snes9x2010_libretro.so", 0o100600),
                             ("alien3.smc", 0o100600), ("retroarch.cfg", 0o100600),
                             ("autoconfig/Nintendo Clovercon - controller1.cfg", 0o100600), ("trial-start", 0o100700)] {
            add("probe/compat/" + name, mode, try Data(contentsOf: root.appendingPathComponent(name)))
        }
        add("probe/trial-report", 0o100700, try Data(contentsOf: URL(fileURLWithPath: reportPath)))
        let marker = "startup_stage starting-menu\n"
        guard let boundary = originalRun.range(of: marker),
              originalRun[boundary.lowerBound...].contains("/usr/bin/clover-mcp --gui snes-usa") else {
            throw RecoveryImageError.invalid("The input does not have the expected menu launch boundary.")
        }
        // Experimental image assembly only. The host-side launch/report protocol
        // for this new state is not implemented, so this must not be booted.
        let directLaunch = #"""
        test ! -e /probe/trial.pid && test ! -L /probe/trial.pid || fail trial-owner
        startup_stage starting-trial
        "$B" env -i PATH=/sbin:/usr/sbin:/bin:/usr/bin HOME=/root USER=root LANG=C LC_ALL=C \
          "$B" chroot /newroot /run/swifthakchi/compat/trial-start > /probe/menu.pipe 2>&1 &
        trial=$!
        if ! (set -C; printf '%s\n' "$trial" > /probe/trial.pid); then
          kill "$trial" 2>/dev/null || :
          fail trial-owner
        fi
        "$B" sleep 2
        kill -0 "$trial" 2>/dev/null || fail trial-exited
        startup_stage trial-running
        trap - EXIT
        while kill -0 "$trial" 2>/dev/null; do
          daemon=$("$B" cat /probe/daemon.pid)
          kill -0 "$daemon" 2>/dev/null || fail daemon-exited
          "$B" sleep 2
        done
        fail trial-exited
        """# + "\n"
        let modifiedRun = Data((String(originalRun[..<boundary.lowerBound]) + directLaunch).utf8)
        var checked = originalFiles
        checked["probe/run"] = modifiedRun
        for entry in entries where entry.fields[1] & 0xf000 == 0x8000 { checked[entry.name] = entry.data }
        let manifest = Data(checked.keys.sorted().map { BackupManifest.digest(checked[$0]!) + "  /" + $0 + "\n" }.joined().utf8)
        #expect(prepared.filesSHA256 == BackupManifest.digest(manifest))
        #expect(try LegacyBootImageBuilder.inspect(prepared.image).archive.entries.first(where: { $0.name == "probe/run" })?.data == modifiedRun)
        let replacements = ["probe/run": modifiedRun, "probe/files.sha256": manifest]
        let archive = try original.archive.updating(replacements: replacements, additions: entries)
        let image = try LegacyBootImageBuilder.build(source: source, kernel: original.kernel, archive: archive, ramdiskEncoding: .lzopCompressed)
        let inspected = try LegacyBootImageBuilder.inspect(image)
        guard inspected.kernel == original.kernel, inspected.archive == archive else {
            throw RecoveryImageError.invalid("The offline candidate did not round-trip.")
        }
        for entry in original.archive.entries where replacements[entry.name] == nil {
            var expected = entry
            if entry.name == "probe" { expected.fields[4] += 1 }
            guard inspected.archive.entries.contains(expected) else {
                throw RecoveryImageError.invalid("An existing archive entry changed.")
            }
        }
        for (name, data) in replacements {
            guard inspected.archive.entries.first(where: { $0.name == name })?.data == data else {
                throw RecoveryImageError.invalid("The trial startup or manifest did not round-trip.")
            }
        }
        let probeEntries = archive.entries.filter { $0.name == "probe" || $0.name.hasPrefix("probe/") }
        let probeBytes = probeEntries.reduce(0) { $0 + $1.data.count }
        print("HC_TRIAL_CAPACITY source=\(source.count) image=\(image.count) encoded=\(try archive.encoded().count) payload=\(entries.reduce(0) { $0 + $1.data.count }) probeBytes=\(probeBytes) probeEntries=\(probeEntries.count)")
    }
}
