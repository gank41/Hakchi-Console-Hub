import Foundation

/// There is deliberately no burn/restore command in this namespace.
enum SNESPreparationCommands {
    static let directory = "/tmp/swifthakchi-snes-preparation"
    static func created(id: UUID) -> String { "SWIFTHAKCHI_SNES_PREPARATION_CREATED_V1 \(id.uuidString)\n" }
    static func staged(id: UUID) -> String { "SWIFTHAKCHI_SNES_PREPARATION_CHECKED_V1 \(id.uuidString) \(SNESOfflineSource.stockSHA256)\n" }
    private static let scratchCheck = #"""
    test -d /tmp && test ! -L /tmp || exit 28
    awk '$2=="/" { n++; good=($1=="rootfs" && $3=="rootfs" && index("," $4 ",",",rw,")) } $2=="/tmp" || index($2,"/tmp/")==1 { bad=1 } END { if(n!=1 || !good || bad) exit 1 }' /proc/mounts || exit 29
    """#
    static func create(id: UUID) -> String {
        "set -eu\n" + StockRestoreCommands.pins + "\n" + scratchCheck + "\n" + #"""
        umask 077
        d='/tmp/swifthakchi-snes-preparation'
        mkdir "$d" || exit 30
        chmod 700 "$d"
        printf '%s\n' '\#(id.uuidString)' > "$d/owner"
        : > "$d/stock.img"
        chmod 600 "$d/owner" "$d/stock.img"
        printf '%s' '\#(created(id: id))'
        """#
    }
    static func checkedStage(id: UUID) -> String {
        "set -eu\n" + StockRestoreCommands.pins + "\n" + scratchCheck + "\n" + #"""
        d='/tmp/swifthakchi-snes-preparation'
        test -d "$d" && test ! -L "$d" || exit 31
        for file in owner stock.img; do
          test -f "$d/$file" && test ! -L "$d/$file" && test "$(stat -c %h "$d/$file")" = 1 || exit 32
        done
        test "$(cat "$d/owner")" = '\#(id.uuidString)' || exit 33
        validate_stock() {
          test "$(wc -c < "$d/stock.img" | tr -d '[:space:]')" = 2736128 || exit 34
          sum=$(sha256sum "$d/stock.img") || exit 35
          test "${sum%% *}" = '\#(SNESOfflineSource.stockSHA256)' || exit 35
        }
        validate_stock
        (ulimit -f 32 || exit 36; /bin/sntool check "$d/stock.img") > "$d/check.out" 2> "$d/check.err" || exit 37
        test "$(wc -c < "$d/check.out")" -le 16384 && test "$(wc -c < "$d/check.err")" -le 16384 || exit 38
        validate_stock
        printf '%s' '\#(staged(id: id))'
        """#
    }
}
