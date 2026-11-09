import Foundation

/// Builds a pinned, memory-only developer trial. It does not authorize a boot.
public enum SNESAlienTrialImageBuilder {
    public struct Result: Sendable {
        public let image: Data
        public let filesSHA256: String
        public let probeBytes: Int
    }
    public static func build(source: Data, payload: [String: Data], report: Data) throws -> Result {
        var hashes = [
            "retroarch": "c2025cc98f2b755ef6759ead70a8e6dfe5aa85ff6772b78daa92bf91ad936e14",
            "snes9x2010_libretro.so": "ea4fab232ce2479c61099240d20196172051027fb7f55a9eabf2c5d9c4342286",
            "alien3.smc": "65feac0ff8bf834bdb3f1eade09102496e1bd021a261ca05fc3a75983c357c84",
            "retroarch.cfg": "d8dd1659a886e110745171e448055aa11497d44b82e4ac35f879668ac2f3d59b",
            "autoconfig/Nintendo Clovercon - controller1.cfg": "55018944a935bd04858d80f0f99d5a7ecfb61353565ba565eedd0075a55d2c35",
            "trial-start": "29428e580d8bec2ac3c9945f1d0e2cdd317b33b9c9d65ad93d97c43bac6b8f0f"
        ]
        let sramTrial = payload["trial-sram-owner"] != nil
        let resetTrial = payload["trial-reset-owner"] != nil
        let powerTrial = payload["trial-owner"] != nil
        if sramTrial {
            hashes.removeValue(forKey: "alien3.smc")
            hashes["simcity.smc"] = "bf74c58e4190faca2f3a967dc190fe529d13887d1262b72e057b5353e43cf67f"
            hashes["retroarch"] = "9fd3707d1fcc3257cd8c57a988c75eefaf4d7b5e6838e34e67df74e277c6a2df"
            hashes["retroarch.cfg"] = "68a1951f54441c93f3dfa653f88bae32afe72ebb68b66422be212e1c54a1904f"
            hashes["trial-sram-owner"] = "cb45b19294730afa347ec52c720f445f92c6210ea4ec446ecbd898aa9ec783da"
            hashes["trial-start"] = "ba192b55ee112d1b12a8f19e5139bd4dbf77d0b494e9fb4ca4be9f70553be90c"
        } else if resetTrial {
            hashes["trial-reset-owner"] = "bb6919250e34419a35cec9697cbeb70ff9659729b24a9ddb6b155b07ca5bf5ce"
            hashes["trial-start"] = "cdce1417eac760ec50332ce462b05cb3979e7fffc81ffbafc3a03aaae23c1443"
        } else if powerTrial {
            hashes["trial-owner"] = "bc895f01ce7730d1f222a4ab1dd1524ac16ee426c31337b17b692d151f61ccb8"
            hashes["trial-start"] = "94b592f45b2f266b1eeb12ccac99833e8baf70df1d6f57fd371bee77a2513748"
        }
        let reportHash = sramTrial ? "7ff03bf7b6c2b8ddec1995382733faa28af40401b7efc0927fa2b8db0406b7b8" : (resetTrial ? "4104f8cdae3e26fc1d8c5c3c71a7a3eff714907d4b6349afcaabfac3e23fbabb" : (powerTrial ? "7453eff06fdba2c5e401f02f1e65871b70dcabec4c541a21aae69349b807298c" : "cbee82b7e039c7078fe4a7b1273a3e422b8b5cb323d43d7504c44e4c0034694a"))
        let names = hashes.keys.sorted()
        guard Set(payload.keys) == Set(names), names.allSatisfy({ BackupManifest.digest(payload[$0]!) == hashes[$0]! }),
              BackupManifest.digest(report) == reportHash else {
            throw RecoveryImageError.invalid("The trial files differ from the reviewed candidate.")
        }
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
        var entries: [NewcEntry] = []
        func add(_ path: String, _ mode: UInt32, _ data: Data) {
            entries.append(NewcEntry(name: path, fields: [UInt32(62000 + entries.count), mode, 0, 0,
                mode & 0xf000 == 0x4000 ? 2 : 1, 0, UInt32(data.count), 0, 0, 0, 0,
                UInt32(path.utf8.count + 1), 0], data: data))
        }
        add("probe/compat", 0o40700, Data())
        add("probe/compat/autoconfig", 0o40700, Data())
        for name in names {
            let mode: UInt32 = ["retroarch", "trial-start", "trial-owner", "trial-reset-owner", "trial-sram-owner"].contains(name) ? 0o100700 : 0o100600
            add("probe/compat/" + name, mode, payload[name]!)
        }
        add("probe/trial-report", 0o100700, report)
        let marker = "startup_stage starting-menu\n"
        guard let boundary = originalRun.range(of: marker),
              originalRun[boundary.lowerBound...].contains("/usr/bin/clover-mcp --gui snes-usa") else {
            throw RecoveryImageError.invalid("The input does not have the expected menu launch boundary.")
        }
        // Developer-only RAM trial; a separate reviewed coordinator owns the
        // checkpoint, release and process report. Hardware behavior remains unverified.
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
        let probeBytes = archive.entries.filter { $0.name == "probe" || $0.name.hasPrefix("probe/") }.reduce(0) { $0 + $1.data.count }
        guard probeBytes < 16 * 1024 * 1024 else { throw RecoveryImageError.invalid("The trial exceeds its temporary storage limit.") }
        return Result(image: image, filesSHA256: BackupManifest.digest(manifest), probeBytes: probeBytes)
    }
}
