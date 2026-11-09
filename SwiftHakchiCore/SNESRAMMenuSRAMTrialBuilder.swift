import Foundation

/// Local, RAM-only experiment. It does not authorize a boot or enable sync.
public enum SNESRAMMenuSRAMTrialBuilder {
    public static let ownerSHA256 = "d610279e0d599fe0fe68f7585cdc81584892aac51d630b84c622af2e97f751da"
    public static func build(source: Data, alienPayload: [String: Data], alienReport: Data,
                             artwork: Data, resetOwner: Data, signalOwner: Data,
                             savePayload: [String: Data], saveReport: Data,
                             saveMenuOwner: Data) throws -> SNESRAMCompatibilityMenuBuilder.Result {
        func bad() -> RecoveryImageError { .invalid("The temporary menu save-test inputs differ from the reviewed candidate.") }
        guard BackupManifest.digest(saveMenuOwner) == ownerSHA256 else { throw bad() }
        // Authenticate the previously reviewed Sim City frontend, core, ROM,
        // controller, script and report before using any of those files.
        _ = try SNESAlienTrialImageBuilder.build(source: source, payload: savePayload, report: saveReport)
        let base = try SNESRAMMenuSignalTrialBuilder.build(source: source, payload: alienPayload, report: alienReport,
                                                           artwork: artwork, resetOwner: resetOwner, signalOwner: signalOwner)
        let image = try LegacyBootImageBuilder.inspect(base.image)
        guard let startData = image.archive.entries.first(where: { $0.name == "probe/compat/trial-start" })?.data,
              var start = String(data: startData, encoding: .utf8),
              let desktopData = image.archive.entries.first(where: { $0.name == "probe/menu/CLV-U-ZZZZZ/CLV-U-ZZZZZ.desktop" })?.data,
              var desktop = String(data: desktopData, encoding: .utf8),
              let frontend = savePayload["retroarch"], let config = savePayload["retroarch.cfg"],
              let rom = savePayload["simcity.smc"] else { throw bad() }
        func once(_ text: inout String, _ old: String, _ new: String) throws {
            guard text.components(separatedBy: old).count == 2 else { throw bad() }
            text = text.replacingOccurrences(of: old, with: new)
        }
        for (old, new) in [
            ("S=/tmp/hc-alien3-trial", "S=/tmp/hc-simcity-trial"),
            ("check \"$R/alien3.smc\" 65feac0ff8bf834bdb3f1eade09102496e1bd021a261ca05fc3a75983c357c84", "check \"$R/simcity.smc\" bf74c58e4190faca2f3a967dc190fe529d13887d1262b72e057b5353e43cf67f"),
            ("c2025cc98f2b755ef6759ead70a8e6dfe5aa85ff6772b78daa92bf91ad936e14", "9fd3707d1fcc3257cd8c57a988c75eefaf4d7b5e6838e34e67df74e277c6a2df"),
            ("d8dd1659a886e110745171e448055aa11497d44b82e4ac35f879668ac2f3d59b", "68a1951f54441c93f3dfa653f88bae32afe72ebb68b66422be212e1c54a1904f"),
            (SNESRAMMenuSignalTrialBuilder.ownerSHA256, ownerSHA256)
        ] { try once(&start, old, new) }
        try once(&desktop, "Name=Alien 3 (Temporary Test)", "Name=Sim City 2000 (Temporary Test)")
        try once(&desktop, "SortRawTitle=Alien 3", "SortRawTitle=Sim City 2000")
        var entries = image.archive.entries
        guard let index = entries.firstIndex(where: { $0.name == "probe/compat/alien3.smc" }) else { throw bad() }
        let romPath = "probe/compat/simcity.smc"
        entries[index].name = romPath
        entries[index].data = rom
        entries[index].fields[6] = UInt32(rom.count)
        entries[index].fields[11] = UInt32(romPath.utf8.count + 1)
        let renamed = try NewcArchive(entries: entries)
        var files = Dictionary(uniqueKeysWithValues: renamed.entries.filter {
            $0.fields[1] & 0xf000 == 0x8000 && $0.name != "probe/files.sha256"
        }.map { ($0.name, $0.data) })
        let replacements: [String: Data] = [
            "probe/compat/trial-start": Data(start.utf8),
            "probe/compat/trial-menu-owner": saveMenuOwner,
            "probe/compat/retroarch": frontend,
            "probe/compat/retroarch.cfg": config,
            "probe/menu/CLV-U-ZZZZZ/CLV-U-ZZZZZ.desktop": Data(desktop.utf8)
        ]
        for (name, data) in replacements { files[name] = data }
        let manifest = Data(files.keys.sorted().map { BackupManifest.digest(files[$0]!) + "  /" + $0 + "\n" }.joined().utf8)
        var edits = replacements; edits["probe/files.sha256"] = manifest
        let archive = try renamed.updating(replacements: edits)
        let size = archive.entries.filter { $0.name == "probe" || $0.name.hasPrefix("probe/") }.reduce(0) { $0 + $1.data.count }
        guard size < 16 * 1024 * 1024 else { throw bad() }
        let result = try LegacyBootImageBuilder.build(source: source, kernel: image.kernel, archive: archive, ramdiskEncoding: .lzopCompressed)
        let checked = try LegacyBootImageBuilder.inspect(result)
        guard checked.kernel == image.kernel, checked.archive == archive else { throw bad() }
        return .init(image: result, filesSHA256: BackupManifest.digest(manifest))
    }
}
