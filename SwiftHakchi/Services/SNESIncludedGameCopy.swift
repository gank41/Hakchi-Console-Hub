import Foundation
import SwiftHakchiCore

/// Extracts the cartridge data only after verifying the complete captured console file.
enum SNESIncludedGameCopy {
    static let chunkSize = 256 * 1024

    static func count(entry: SNESOriginalGamesFrame.Entry, offset: Int) throws -> Int {
        guard entry.code.range(of: #"^CLV-P-[A-Z0-9]{5}$"#, options: .regularExpression) != nil,
              entry.romName == entry.code + ".sfrom", SNESDataSnapshotChunk.isDigest(entry.romSHA256),
              (96...16 * 1024 * 1024).contains(entry.romBytes), offset >= 0,
              offset % chunkSize == 0, offset < entry.romBytes else { throw SNESOriginalGamesFrame.failure() }
        return min(chunkSize, entry.romBytes - offset)
    }

    static func command(context: SNESLibraryContext, entry: SNESOriginalGamesFrame.Entry, offset: Int, challenge: UUID) throws -> String {
        let count = try count(entry: entry, offset: offset)
        let path = "/usr/share/games/\(entry.code)/\(entry.romName)"
        return try SNESLibraryInventoryCommands.prefix(context: context.sha256, hwid: context.installation.expected.hwid,
                                                        runtime: context.installation.expected.runtimeSHA256) + #"""
        p=__PATH__
        directory /usr; directory /usr/share; directory /usr/share/games; directory "${p%/*}"
        named() { regular "$p"; test "$("$B" stat -c '%s' "$p")" = __SIZE__; value=$("$B" sha256sum "$p"); test "${value%% *}" = __SHA__; }
        named
        exec 7< "$p"
        source="/proc/$$/fd/7"
        test -f "$source"
        value=$("$B" dd if="$source" bs=262144 skip=__BLOCK__ count=1 2>/dev/null | "$B" sha256sum); hash=${value%% *}
        test "${#hash}" -eq 64; case "$hash" in *[!0-9a-f]*) exit 1;; esac
        printf 'SWIFTHAKCHI_INCLUDED_CHUNK_V1 __NONCE__ __CONTEXT__ __CODE__ __OFFSET__ __COUNT__ %s\n' "$hash"
        "$B" dd if="$source" bs=262144 skip=__BLOCK__ count=1 2>/dev/null
        named; no_game; exec 7<&-
        printf '\nSWIFTHAKCHI_INCLUDED_CHUNK_END_V1 __NONCE__ %s\n' "$hash"
        """#.replacingOccurrences(of: "__PATH__", with: LaunchCommand.shellQuote(path))
            .replacingOccurrences(of: "__SIZE__", with: String(entry.romBytes))
            .replacingOccurrences(of: "__SHA__", with: entry.romSHA256)
            .replacingOccurrences(of: "__BLOCK__", with: String(offset / chunkSize))
            .replacingOccurrences(of: "__NONCE__", with: challenge.uuidString)
            .replacingOccurrences(of: "__CONTEXT__", with: context.sha256)
            .replacingOccurrences(of: "__CODE__", with: entry.code)
            .replacingOccurrences(of: "__OFFSET__", with: String(offset))
            .replacingOccurrences(of: "__COUNT__", with: String(count)) + "\n"
    }

    static func chunk(_ raw: Data, entry: SNESOriginalGamesFrame.Entry, offset: Int, challenge: UUID, context: String) throws -> Data {
        let count = try count(entry: entry, offset: offset)
        guard SNESDataSnapshotChunk.isDigest(context), raw.count <= count + 2048,
              let newline = raw.prefix(1024).firstIndex(of: 10),
              let header = String(data: raw[..<newline], encoding: .ascii) else { throw SNESOriginalGamesFrame.failure() }
        let fields = header.components(separatedBy: " ")
        guard fields.count == 7, fields[0] == "SWIFTHAKCHI_INCLUDED_CHUNK_V1", fields[1] == challenge.uuidString,
              fields[2] == context, fields[3] == entry.code, fields[4] == String(offset), fields[5] == String(count),
              SNESDataSnapshotChunk.isDigest(fields[6]), raw.count >= newline + 1 + count else { throw SNESOriginalGamesFrame.failure() }
        let end = newline + 1 + count
        let footer = Data("\nSWIFTHAKCHI_INCLUDED_CHUNK_END_V1 \(challenge.uuidString) \(fields[6])\n".utf8)
        guard Data(raw[end...]) == footer else { throw SNESOriginalGamesFrame.failure() }
        let body = Data(raw[(newline + 1)..<end])
        guard BackupManifest.digest(body) == fields[6] else { throw SNESOriginalGamesFrame.failure() }
        return body
    }
    static func rawROM(from image: Data, entry: SNESOriginalGamesFrame.Entry) throws -> Data {
        guard image.count == entry.romBytes, image.count >= 96,
              image.count <= 16 * 1024 * 1024,
              BackupManifest.digest(image) == entry.romSHA256,
              Data(image.prefix(48)) + Data(image.suffix(48)) == entry.headers else {
            throw SNESOriginalGamesFrame.failure()
        }
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(image[offset + $1]) << (8 * $1)) }
        }
        let start = word(8), end = word(12)
        guard word(0) == 0x100, word(4) == image.count, start == 48,
              end > start, end <= image.count - 48,
              end - start <= 4 * 1024 * 1024 else { throw SNESOriginalGamesFrame.failure() }
        return Data(image[start..<end])
    }
}
