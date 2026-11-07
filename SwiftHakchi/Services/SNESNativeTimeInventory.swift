import Foundation

/// Read-only format observation. Samples are not authorization to write a
/// play-time file and do not establish which software produced them.
struct SNESNativeTimeInventory {
    enum Invalid: Error { case frame }
    enum Kind: String { case stock = "STOCK", added = "ADDED" }
    let samples: [Data]
    let kinds: [Kind]

    static func parse(_ input: Data) throws -> Self {
        guard input.count <= 1024, let text = String(data: input, encoding: .utf8) else { throw Invalid.frame }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 3, lines.first == "SNES-TIME-V1", lines.last == "", lines[lines.count - 2] == "END" else { throw Invalid.frame }
        var samples: [Data] = []
        var kinds: [Kind] = []
        for line in lines.dropFirst().dropLast(2) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0] == "SAMPLE", let kind = Kind(rawValue: String(fields[1])), let n = Int(fields[2]),
                  n >= 0, n <= 32, String(n) == fields[2], samples.count < 8 else { throw Invalid.frame }
            kinds.append(kind)
            if n == 0 { guard fields[3] == "-" else { throw Invalid.frame }; samples.append(Data()); continue }
            let hex = Array(fields[3].utf8)
            guard hex.count == n * 2, hex.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Invalid.frame }
            func digit(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
            samples.append(Data(stride(from: 0, to: hex.count, by: 2).map { digit(hex[$0]) * 16 + digit(hex[$0 + 1]) }))
        }
        return Self(samples: samples, kinds: kinds)
    }

    /// Reads only small existing `state.time` files under direct game and slot
    /// directories. It skips links before and after reading, but does not
    /// exclude path replacement. No pathname is emitted and nothing is written.
    /// Identical bounded reads do not establish console or writer identity.
    static let command = #"""
    set -eu
    set -o pipefail
    B=/mnt/swifthakchi/busybox
    P=/var/lib/clover/profiles/0
    test -d "$P" && test ! -L "$P"
    printf 'SNES-TIME-V1\n'
    count=0; games=0
    for game in "$P"/CLV-?-?????; do
      test -d "$game" && test ! -L "$game" || continue
      code=${game##*/}
      case "$code" in
        CLV-P-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) kind=STOCK;;
        CLV-U-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) kind=ADDED;;
        *) continue;;
      esac
      games=$((games+1)); test "$games" -le 512
      for number in 0 1 2 3 4; do
        slot="$game/suspendpoint$number"; file="$slot/state.time"
        test -d "$slot" && test ! -L "$slot" && test -f "$file" && test ! -L "$file" || continue
        size=$("$B" stat -c '%s' "$file") || continue
        case "$size" in ''|*[!0-9]*) continue;; esac
        test "$size" -le 32 || continue
        first=$("$B" head -c 33 "$file" | "$B" od -An -v -tx1 | "$B" tr -d ' \n')
        second=$("$B" head -c 33 "$file" | "$B" od -An -v -tx1 | "$B" tr -d ' \n')
        size2=$("$B" stat -c '%s' "$file") || continue
        test "$size" = "$size2" && test "$first" = "$second" && test "${#first}" -eq $((size*2)) || continue
        test -f "$file" && test ! -L "$file" && test -d "$slot" && test ! -L "$slot" || continue
        if test "$size" = 0; then first=-; fi
        printf 'SAMPLE %s %s %s\n' "$kind" "$size" "$first"
        count=$((count+1)); test "$count" -lt 8 || break 2
      done
    done
    printf 'END\n'
    """#
}
