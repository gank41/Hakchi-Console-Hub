import Foundation

/// A lower bound for the temporary space needed by a legacy NES menu sync.
/// Folder artwork and archive metadata can increase the final reviewed amount.
struct LegacySyncCapacityEstimate: Sendable {
    struct Projection: Equatable, Sendable {
        let freeBytes: Int64
        let requiredBytes: Int64
        var headroomBytes: Int64 { freeBytes - requiredBytes }
    }

    let freeBytes: Int64
    let stockCodes: Set<String>
    /// ROM, desktop and cover bytes for each local game; absent means unknown.
    let sourceBytes: [String: Int64]

    func projected(_ selectedCodes: Set<String>) -> Projection? {
        guard freeBytes >= 0 else { return nil }
        var stageBytes: Int64 = 4096
        for code in selectedCodes {
            let fileBytes: Int64
            if stockCodes.contains(code) {
                fileBytes = 0
            } else {
                guard let known = sourceBytes[code], known >= 0 else { return nil }
                fileBytes = known
            }
            let (withFiles, firstOverflow) = stageBytes.addingReportingOverflow(fileBytes)
            let (withAllowance, secondOverflow) = withFiles.addingReportingOverflow(64 * 1024)
            guard !firstOverflow, !secondOverflow else { return nil }
            stageBytes = withAllowance
        }
        let (twoCopies, copyOverflow) = stageBytes.multipliedReportingOverflow(by: 2)
        let (required, reserveOverflow) = twoCopies.addingReportingOverflow(64 * 1024 * 1024)
        guard !copyOverflow, !reserveOverflow else { return nil }
        return Projection(freeBytes: freeBytes, requiredBytes: required)
    }

    /// Unknown source sizes remain selectable; the exact review will check them.
    func canInclude(_ code: String, in selectedCodes: Set<String>) -> Bool {
        guard !selectedCodes.contains(code),
              let projection = projected(selectedCodes.union([code])) else { return true }
        return projection.headroomBytes >= 0
    }

    static func fromLibrary(localGames: [Game], stockCodes: Set<String>, freeBytes: Int64) -> Self {
        var sizes: [String: Int64] = [:]
        for game in localGames where game.source == .local {
            let folder = URL(fileURLWithPath: game.romPath, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
                  entries.filter({ $0.pathExtension.lowercased() == "nes" }).count == 1,
                  let rom = entries.first(where: { $0.pathExtension.lowercased() == "nes" }),
                  let romBytes = regularFileSize(rom),
                  let desktopBytes = regularFileSize(folder.appendingPathComponent(game.code + ".desktop")),
                  let coverBytes = regularFileSize(folder.appendingPathComponent(game.code + ".png")) else { continue }
            let (sum, firstOverflow) = romBytes.addingReportingOverflow(desktopBytes)
            let (total, secondOverflow) = sum.addingReportingOverflow(coverBytes)
            if !firstOverflow, !secondOverflow { sizes[game.code] = total }
        }
        return Self(freeBytes: freeBytes, stockCodes: stockCodes, sourceBytes: sizes)
    }

    private static func regularFileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else { return nil }
        return Int64(size)
    }
}
