import Foundation

/// Two-session RAM-only experiment. It does not enable installation or sync.
public enum SNESRAMMenuDKC3TrialBuilder {
    public static let ownerSHA256 = "0fe06a432736720f28aea977db76008731190a98ec0283eb3a4c79cc224319e5"
    private static let romSHA256 = "1743175bf35cc5c16c3def96589e9b0528364984e1c35f7e47a4d5a407f2b233"
    private static let configSHA256 = "b38206049b4fdbf0dd2edb267ac4efe9a710a94cb6539cd32ab0c5ae43339389"
    private static let reentrySHA256 = "685570891facb40ead70777c242a8e11ad69bc740d8528777a89b2a481b2c2dc"
    public static func build(source: Data, alienPayload: [String: Data], alienReport: Data, artwork: Data,
                             resetOwner: Data, signalOwner: Data, savePayload: [String: Data], saveReport: Data,
                             saveMenuOwner: Data, rom: Data, config: Data, owner: Data,
                             reentry: Data) throws -> SNESRAMCompatibilityMenuBuilder.Result {
        func bad() -> RecoveryImageError { .invalid("The two-session RAM save-test inputs differ from the reviewed candidate.") }
        guard BackupManifest.digest(rom) == romSHA256, BackupManifest.digest(config) == configSHA256,
              BackupManifest.digest(owner) == ownerSHA256, BackupManifest.digest(reentry) == reentrySHA256,
              let reentryScript = String(data: reentry, encoding: .utf8), reentryScript.hasSuffix("\n") else { throw bad() }
        let base = try SNESRAMMenuSRAMTrialBuilder.build(source: source, alienPayload: alienPayload, alienReport: alienReport,
            artwork: artwork, resetOwner: resetOwner, signalOwner: signalOwner, savePayload: savePayload,
            saveReport: saveReport, saveMenuOwner: saveMenuOwner)
        let image = try LegacyBootImageBuilder.inspect(base.image)
        guard let startData = image.archive.entries.first(where: { $0.name == "probe/compat/trial-start" })?.data,
              var start = String(data: startData, encoding: .utf8),
              let desktopData = image.archive.entries.first(where: { $0.name == "probe/menu/CLV-U-ZZZZZ/CLV-U-ZZZZZ.desktop" })?.data,
              var desktop = String(data: desktopData, encoding: .utf8) else { throw bad() }
        func once(_ text: inout String, _ old: String, _ new: String) throws {
            guard text.components(separatedBy: old).count == 2 else { throw bad() }
            text = text.replacingOccurrences(of: old, with: new)
        }
        for (old,new) in [
            ("S=/tmp/hc-simcity-trial", "S=/tmp/hc-dkc3-trial"),
            ("check \"$R/simcity.smc\" bf74c58e4190faca2f3a967dc190fe529d13887d1262b72e057b5353e43cf67f", "check \"$R/dkc3.smc\" " + romSHA256),
            ("68a1951f54441c93f3dfa653f88bae32afe72ebb68b66422be212e1c54a1904f", configSHA256),
            (SNESRAMMenuSRAMTrialBuilder.ownerSHA256, ownerSHA256)
        ] { try once(&start, old, new) }
        try once(&start, "test ! -e \"$observation\" && test ! -L \"$observation\"", reentryScript + "{ test ! -e \"$observation\" && test ! -L \"$observation\"; } || exit 1")
        let oldScratch = "test ! -e \"$S\" && test ! -L \"$S\"\n\"$B\" mkdir -m 0700 \"$S\""
        let newScratch = "if test \"$reentry\" = 0; then\n  { test ! -e \"$S\" && test ! -L \"$S\"; } || exit 1\n  \"$B\" mkdir -m 0700 \"$S\"\nfi"
        try once(&start, oldScratch, newScratch)
        try once(&desktop, "Name=Sim City 2000 (Temporary Test)", "Name=Donkey Kong Country 3 (Temporary Test)")
        try once(&desktop, "SortRawTitle=Sim City 2000", "SortRawTitle=Donkey Kong Country 3")
        var entries = image.archive.entries
        guard let index = entries.firstIndex(where: { $0.name == "probe/compat/simcity.smc" }) else { throw bad() }
        let romPath = "probe/compat/dkc3.smc"
        entries[index].name = romPath; entries[index].data = rom
        entries[index].fields[6] = UInt32(rom.count); entries[index].fields[11] = UInt32(romPath.utf8.count + 1)
        let renamed = try NewcArchive(entries: entries)
        var files = Dictionary(uniqueKeysWithValues: renamed.entries.filter {
            $0.fields[1] & 0xf000 == 0x8000 && $0.name != "probe/files.sha256"
        }.map { ($0.name, $0.data) })
        let changes: [String: Data] = ["probe/compat/trial-start": Data(start.utf8), "probe/compat/trial-menu-owner": owner,
            "probe/compat/retroarch.cfg": config, "probe/menu/CLV-U-ZZZZZ/CLV-U-ZZZZZ.desktop": Data(desktop.utf8)]
        for (name,data) in changes { files[name] = data }
        let manifest = Data(files.keys.sorted().map { BackupManifest.digest(files[$0]!) + "  /" + $0 + "\n" }.joined().utf8)
        var edits = changes; edits["probe/files.sha256"] = manifest
        let archive = try renamed.updating(replacements: edits)
        let size = archive.entries.filter { $0.name == "probe" || $0.name.hasPrefix("probe/") }.reduce(0) { $0 + $1.data.count }
        guard size < 16 * 1024 * 1024 else { throw bad() }
        let result = try LegacyBootImageBuilder.build(source: source, kernel: image.kernel, archive: archive, ramdiskEncoding: .lzopCompressed)
        let checked = try LegacyBootImageBuilder.inspect(result)
        guard checked.kernel == image.kernel, checked.archive == archive else { throw bad() }
        return .init(image: result, filesSHA256: BackupManifest.digest(manifest))
    }
}
