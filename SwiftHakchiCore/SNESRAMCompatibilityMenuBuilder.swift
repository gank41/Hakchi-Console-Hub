import Foundation
import ImageIO

/// Offline experiment only: produces no console write and grants no boot permission.
/// The trial owner does not yet implement the stock menu's transition protocol.
public enum SNESRAMCompatibilityMenuBuilder {
    public struct Result: Sendable { public let image: Data; public let filesSHA256: String }
    public static func build(source: Data, payload: [String: Data], report: Data, artwork: Data) throws -> Result {
        func bad() -> RecoveryImageError { .invalid("The temporary compatibility-menu inputs do not match the reviewed trial.") }
        guard artwork.count >= 8, artwork.count <= 262144,
              Array(artwork.prefix(8)) == [137,80,78,71,13,10,26,10],
              let imageSource = CGImageSourceCreateWithData(artwork as CFData, nil),
              CGImageSourceGetCount(imageSource) == 1,
              let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              decoded.width > 0, decoded.height > 0, decoded.width <= 228, decoded.height <= 204,
              let sourceStart = payload["trial-start"].flatMap({ String(data: $0, encoding: .utf8) }) else { throw bad() }
        let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                 kCGImageSourceThumbnailMaxPixelSize: 40]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary),
              thumbnail.width > 0, thumbnail.height > 0, thumbnail.width <= 40, thumbnail.height <= 40 else { throw bad() }
        let small = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(small, "public.png" as CFString, 1, nil) else { throw bad() }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination), small.length <= 262144 else { throw bad() }
        // The inner builder authenticates every existing trial component, the
        // original startup image, and the original game, before any changes.
        let trial = try SNESAlienTrialImageBuilder.build(source: source, payload: payload, report: report)
        let original = try LegacyBootImageBuilder.inspect(source)
        let prepared = try LegacyBootImageBuilder.inspect(trial.image)
        guard let runBytes = original.archive.entries.first(where: { $0.name == "probe/run" })?.data,
              var run = String(data: runBytes, encoding: .utf8) else { throw bad() }
        func once(_ text: inout String, _ old: String, _ new: String) throws {
            guard text.components(separatedBy: old).count == 2 else { throw bad() }
            text = text.replacingOccurrences(of: old, with: new)
        }
        var start = sourceStart
        // This is an explicitly disposable RAM trial. It does not consume or
        // publish manager save/screenshot arguments or implement transitions.
        try once(&start, "test \"$#\" -eq 0", "test \"$#\" -le 64\nprintf 'trial-manager-entry\\n' >> \"$trace\"")
        try once(&start, "for process in clover-mcp ReedPlayer-Clover canoe-shvc clover-canoe-shvc retroarch; do",
                 "test \"$(\"$B\" pidof clover-mcp | \"$B\" wc -w | \"$B\" awk '{print $1}')\" = 1\nfor process in canoe-shvc clover-canoe-shvc retroarch; do")
        let observation = #"""
        # Record only the three transition descriptor arguments and their fd
        # types in RAM; never record game paths or other argument values.
        observation=/run/swifthakchi/trial-manager-observation
        test ! -e "$observation" && test ! -L "$observation"
        parent=$("$B" awk '$1=="PPid:" {print $2}' "/proc/$$/status")
        case "$parent" in ''|*[!0-9]*) exit 1;; esac
        (set -C; printf 'HC-MENU-OBS-V1\nPARENT %s\n' "$parent" > "$observation")
        role=
        for arg do
          if test -n "$role"; then
            kind=invalid; number=-
            case "$arg" in
              ''|*[!0-9]*) :;;
              *) if test "${#arg}" -le 3 && test "$arg" -ge 3 && test "$arg" -le 255; then
                   number=$arg
                   target=$("$B" readlink "/proc/$$/fd/$arg" 2>/dev/null || :)
                   case "$target" in 'anon_inode:[eventfd]') kind=eventfd;; '') kind=missing;; *) kind=other;; esac
                 fi;;
            esac
            printf 'ARG %s %s %s\n' "$role" "$number" "$kind" >> "$observation"
            role=
            continue
          fi
          case "$arg" in
            --wait-transition-fd) role=wait;;
            --start-transition-fd) role=start;;
            --finish-transition-fd) role=finish;;
          esac
        done
        test -z "$role" || printf 'ARG %s - invalid\n' "$role" >> "$observation"
        printf 'END\n' >> "$observation"
        stage=display-owner
        """# + "\n"
        try once(&start, "stage=display-owner\n", observation)
        let configure = #"""
        startup_stage preparing-compatibility-menu
        config=/newroot/usr/share/applications/clover-mcp.desktop
        test -f "$config" && test ! -L "$config" || fail menu-config
        test ! -e /probe/menu-selected && test ! -L /probe/menu-selected || fail menu-config-owner
        "$B" awk '
          $0=="GamesFolder = /usr/share/games" {print "GamesFolder = /run/swifthakchi/menu";n++;next}
          {print}
          END {if(n!=1)exit 1}
        ' "$config" > /probe/menu-selected || fail menu-config
        "$B" chmod 0600 /probe/menu-selected
        "$B" mkdir -p /newroot/var/lib/clover/profiles/0/CLV-U-ZZZZZ
        "$B" mount --bind /probe/menu-selected "$config" || fail menu-config-bind
        test "$("$B" stat -c '%d:%i' "$config")" = "$("$B" stat -c '%d:%i' /probe/menu-selected)" || fail menu-config-bind
        startup_stage starting-menu
        """# + "\n"
        try once(&run, "startup_stage starting-menu\n", configure)
        // Restore the original file before the standard ready report, whose
        // mount and source-file checks intentionally admit only stock mounts.
        // Whether the manager has retained this temporary setting is a device
        // behavior to verify; this builder does not assume a successful menu.
        let restore = #"""
        "$B" umount "$config" || fail menu-config-unbind
        require_startup_base
        startup_stage ready
        """# + "\n"
        try once(&run, "startup_stage ready\n", restore)
        let code = "CLV-U-ZZZZZ"
        let desktop = """
        [Desktop Entry]
        Type=Application
        Exec=/run/swifthakchi/compat/trial-start
        Path=/var/lib/clover/profiles/0/\(code)
        Name=Alien 3 (Temporary Test)
        Icon=/run/swifthakchi/menu/\(code)/\(code).png

        [X-CLOVER Game]
        Code=\(code)
        TestID=0
        Status=
        ID=0
        Players=1
        Simultaneous=0
        ReleaseDate=1992-01-01
        SaveCount=0
        SortRawTitle=Alien 3
        SortRawPublisher=Temporary
        Copyright=
        MyPlayDemoTime=0

        """
        var additions: [NewcEntry] = []
        func add(_ name: String, _ mode: UInt32, _ data: Data) {
            additions.append(NewcEntry(name: name, fields: [UInt32(63000 + additions.count), mode, 0, 0,
                mode & 0xf000 == 0x4000 ? 2 : 1, 0, UInt32(data.count), 0, 0, 0, 0,
                UInt32(name.utf8.count + 1), 0], data: data))
        }
        add("probe/menu", 0o40700, Data())
        add("probe/menu/\(code)", 0o40700, Data())
        add("probe/menu/\(code)/\(code).desktop", 0o100600, Data(desktop.utf8))
        add("probe/menu/\(code)/\(code).png", 0o100600, artwork)
        add("probe/menu/\(code)/\(code)_small.png", 0o100600, small as Data)
        var files = Dictionary(uniqueKeysWithValues: prepared.archive.entries.filter {
            $0.fields[1] & 0xf000 == 0x8000 && $0.name != "probe/files.sha256"
        }.map { ($0.name, $0.data) })
        files["probe/run"] = Data(run.utf8)
        files["probe/compat/trial-start"] = Data(start.utf8)
        for entry in additions where entry.fields[1] & 0xf000 == 0x8000 { files[entry.name] = entry.data }
        let manifest = Data(files.keys.sorted().map { BackupManifest.digest(files[$0]!) + "  /" + $0 + "\n" }.joined().utf8)
        let replacements = ["probe/run": Data(run.utf8), "probe/compat/trial-start": Data(start.utf8), "probe/files.sha256": manifest]
        let archive = try prepared.archive.updating(replacements: replacements, additions: additions)
        let bytes = archive.entries.filter { $0.name == "probe" || $0.name.hasPrefix("probe/") }.reduce(0) { $0 + $1.data.count }
        guard bytes < 16 * 1024 * 1024 else { throw bad() }
        let image = try LegacyBootImageBuilder.build(source: source, kernel: original.kernel, archive: archive, ramdiskEncoding: .lzopCompressed)
        let checked = try LegacyBootImageBuilder.inspect(image)
        guard checked.kernel == original.kernel, checked.archive == archive else { throw bad() }
        return .init(image: image, filesSHA256: BackupManifest.digest(manifest))
    }
}
