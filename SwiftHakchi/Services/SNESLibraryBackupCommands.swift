import Foundation
import SwiftHakchiCore

enum SNESLibraryBackupCommands {
    static func script(contextSHA256: String, hwid: String, runtimeSHA256: String, file: SNESLibraryInventory.File,
                       offset: Int, challenge: UUID) throws -> String {
        let count = try SNESLibraryBackupChunk.count(file: file, offset: offset)
        guard SNESLibraryInventory.safePath(file.path), file.byteCount <= (try SNESLibraryInventory.limit(for: file.path)),
              SNESDataSnapshotChunk.isDigest(file.sha256), (0...511).contains(file.mode), file.identity.device <= UInt32.max,
              file.identity.inode > 0, file.identity.inode <= Int64.max, (0...4102444800).contains(file.modified),
              (0...4102444800).contains(file.identity.changed) else { throw SNESLibraryInventory.failure() }
        let path: String
        if file.path.hasPrefix("clover/") { path = "/var/lib/" + file.path }
        else if file.path.hasPrefix("legacy/") { path = "/var/lib/swifthakchi/snes-v1/" + file.path.dropFirst(7) }
        else { path = "/var/lib/swifthakchi/snes-v2/" + file.path }
        let expected = "\(file.identity.device) \(file.identity.inode) \(file.modified) \(file.identity.changed) \(String(file.mode, radix: 8)) \(file.byteCount)"
        let encoded = Data(file.path.utf8).map { String(format: "%02x", $0) }.joined()
        return try SNESLibraryInventoryCommands.prefix(context: contextSHA256, hwid: hwid, runtime: runtimeSHA256) + #"""
        p=__PATH__
        expected=__EXPECTED__
        parents() {
          q=${p%/*}
          while :; do
            case "$q" in /var/lib|/var/lib/*) ;; *) return 1;; esac
            data_directory "$q"
            test "$q" != /var/lib || break
            q=${q%/*}
          done
        }
        named() {
          parents
          regular "$p"
          test "$("$B" stat -c '%d %i %Y %Z %a %s' "$p")" = "$expected"
        }
        named
        exec 7< "$p"
        source="/proc/$$/fd/7"
        held() {
          test -f "$source"
          test "$("$B" stat -L -c '%u' "$source")" = 0
          test "$("$B" stat -L -c '%h' "$source")" = 1
          test "$("$B" stat -L -c '%d %i %Y %Z %a %s' "$source")" = "$expected"
          named
        }
        held
        value=$("$B" dd if="$source" bs=262144 skip=__BLOCK__ count=1 2>/dev/null | "$B" sha256sum);hash=${value%% *}
        test "${#hash}" -eq 64;case "$hash" in *[!0-9a-f]*) exit 1;; esac
        held
        printf 'SWIFTHAKCHI_SNES_LIBRARY_CHUNK_V1 __NONCE__ __CONTEXT__ __ENCODED__ __OFFSET__ __COUNT__ %s\n' "$hash"
        "$B" dd if="$source" bs=262144 skip=__BLOCK__ count=1 2>/dev/null
        held
        no_game
        exec 7<&-
        printf '\nSWIFTHAKCHI_SNES_LIBRARY_CHUNK_END_V1 __NONCE__ %s\n' "$hash"
        """#.replacingOccurrences(of: "__PATH__", with: LaunchCommand.shellQuote(path))
            .replacingOccurrences(of: "__EXPECTED__", with: LaunchCommand.shellQuote(expected))
            .replacingOccurrences(of: "__BLOCK__", with: String(offset / SNESLibraryBackupChunk.maximumBytes))
            .replacingOccurrences(of: "__NONCE__", with: challenge.uuidString).replacingOccurrences(of: "__CONTEXT__", with: contextSHA256)
            .replacingOccurrences(of: "__ENCODED__", with: encoded).replacingOccurrences(of: "__OFFSET__", with: String(offset))
            .replacingOccurrences(of: "__COUNT__", with: String(count)) + "\n"
    }
}
