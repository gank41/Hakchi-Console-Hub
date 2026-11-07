import Foundation

/// Offline developer experiment. It is neither a production launcher nor a
/// permission to boot or write a console; a previewed image must be approved.
public enum SNESRAMMenuResetTrialBuilder {
    public static let ownerSHA256 = "e843c503abaed7ea85d6d28012d10ff3df7a079e897b13d476f429e85e38be1d"
    public static func build(source: Data, payload: [String: Data], report: Data,
                             artwork: Data, owner: Data) throws -> SNESRAMCompatibilityMenuBuilder.Result {
        func bad() -> RecoveryImageError { .invalid("The temporary RESET trial does not match the reviewed owner or menu image.") }
        guard BackupManifest.digest(owner) == ownerSHA256 else { throw bad() }
        let base = try SNESRAMCompatibilityMenuBuilder.build(source: source, payload: payload, report: report, artwork: artwork)
        let image = try LegacyBootImageBuilder.inspect(base.image)
        guard let bytes = image.archive.entries.first(where: { $0.name == "probe/compat/trial-start" })?.data,
              var script = String(data: bytes, encoding: .utf8) else { throw bad() }
        func once(_ old: String, _ new: String) throws {
            guard script.components(separatedBy: old).count == 2 else { throw bad() }
            script = script.replacingOccurrences(of: old, with: new)
        }
        try once("role=\nfor arg do", "waitfd=\nstartfd=\nfinishfd=\nrole=\nfor arg do")
        let record = #"""
        printf 'ARG %s %s %s\n' "$role" "$number" "$kind" >> "$observation"
        if test "$kind" = eventfd; then
          case "$role" in
            wait) test -z "$waitfd"; waitfd=$number;;
            start) test -z "$startfd"; startfd=$number;;
            finish) test -z "$finishfd"; finishfd=$number;;
          esac
        fi
        """#
        try once(#"printf 'ARG %s %s %s\n' "$role" "$number" "$kind" >> "$observation""#, record)
        let end = #"""
        printf 'END\n' >> "$observation"
        test -n "$waitfd" && test -n "$startfd" && test -n "$finishfd"
        test "$waitfd" != "$startfd" && test "$waitfd" != "$finishfd" && test "$startfd" != "$finishfd"
        """#
        try once(#"printf 'END\n' >> "$observation""#, end)
        try once(#"check "$R/trial-owner" bc895f01ce7730d1f222a4ab1dd1524ac16ee426c31337b17b692d151f61ccb8"#,
                 #"check "$R/trial-menu-owner" "# + ownerSHA256)
        try once(#"  "$R/trial-owner""#, #"  "$R/trial-menu-owner" "$waitfd" "$startfd" "$finishfd""#)
        let path = "probe/compat/trial-menu-owner"
        let addition = NewcEntry(name: path, fields: [64000, 0o100700, 0, 0, 1, 0, UInt32(owner.count), 0, 0, 0, 0, UInt32(path.utf8.count+1), 0], data: owner)
        var files = Dictionary(uniqueKeysWithValues:image.archive.entries.filter { $0.fields[1] & 0xf000 == 0x8000 && $0.name != "probe/files.sha256" }.map { ($0.name,$0.data) })
        files["probe/compat/trial-start"] = Data(script.utf8);files[path]=owner
        let manifest = Data(files.keys.sorted().map { BackupManifest.digest(files[$0]!) + "  /" + $0 + "\n" }.joined().utf8)
        let archive = try image.archive.updating(replacements:["probe/compat/trial-start":Data(script.utf8),"probe/files.sha256":manifest],additions:[addition])
        let size = archive.entries.filter { $0.name == "probe" || $0.name.hasPrefix("probe/") }.reduce(0) { $0 + $1.data.count }
        guard size < 16 * 1024 * 1024 else { throw bad() }
        let result = try LegacyBootImageBuilder.build(source:source,kernel:image.kernel,archive:archive,ramdiskEncoding:.lzopCompressed)
        let checked = try LegacyBootImageBuilder.inspect(result)
        guard checked.kernel==image.kernel,checked.archive==archive else { throw bad() }
        return .init(image:result,filesSHA256:BackupManifest.digest(manifest))
    }
}
