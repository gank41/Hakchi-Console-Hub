import Foundation
import CoreGraphics
import ImageIO
import SwiftHakchiCore

/// Builds a separate, checksummed library. Activation belongs to SyncTransactionService.
actor GameSyncService {
    private let shell: any ConsoleShell
    private let consoleType: ConsoleType
    private var checksums: [String: String] = [:]

    init(shell: any ConsoleShell, consoleType: ConsoleType) {
        self.shell = shell; self.consoleType = consoleType
    }

    func prepareStage(plan: SyncPlan, stagingBase: String, finalBase: String,
                      progress: @Sendable (String, Double) -> Void = { _, _ in }) async throws {
        guard consoleType.isNES, plan.profile.systemCode == consoleType.syncCode,
              stagingBase != finalBase, stagingBase.hasPrefix("/") else { throw SyncPlanError.unsupportedConsole }
        checksums = [:]
        _ = try await shell.executeChecked("mkdir -p \(q(stagingBase + "/.storage"))")
        for page in plan.pages {
            let pagePath = stagingBase + "/" + String(format: "%03d", page.number)
            _ = try await shell.executeChecked("mkdir -p \(q(pagePath))")
            for code in page.gameCodes {
                try Task.checkCancellation()
                guard let input = plan.selectedGames.first(where: { $0.code == code }) else { throw SyncPlanError.invalidInput("The sync plan is incomplete.") }
                progress("Preparing \(input.name)...", Double(checksums.count) / Double(max(1, plan.selectedGames.count * 5)))
                if input.isStock {
                    try await stageStock(input, page: pagePath, stage: stagingBase)
                } else {
                    try await stageCustom(input, page: pagePath, stage: stagingBase, final: finalBase)
                }
            }
            if let previous = page.previousPage { try await stageNavigation(target: previous, name: "Previous games", in: pagePath, stage: stagingBase, back: true) }
            if let next = page.nextPage { try await stageNavigation(target: next, name: "More games...", in: pagePath, stage: stagingBase, back: false) }
            let squashfs = "/var/squashfs" + consoleType.originalGamesPath
            _ = try await shell.executeChecked("ln -sfn \(q(squashfs + "/copyright.fnt")) \(q(pagePath + "/copyright.fnt"))")
            _ = try await shell.executeChecked("ln -sfn /var/lib/hakchi/rootfs/usr/share/fonts/title.fnt \(q(pagePath + "/title.fnt"))")
        }
        let marker = Data("SwiftHakchi sync for \(plan.profile.storageKey)\n".utf8)
        try await shell.upload(data: marker, to: stagingBase + "/.sync-info", timeout: 60_000)
        checksums[".sync-info"] = BackupManifest.digest(marker)
        let manifest = checksums.keys.sorted().map { "\(checksums[$0]!)  \($0)\n" }.joined()
        try await shell.upload(data: Data(manifest.utf8), to: stagingBase + "/.sync-checksums", timeout: 60_000)
        _ = try await shell.executeChecked("cd \(q(stagingBase)) && sha256sum -c .sync-checksums", timeout: 300_000)
    }

    private func stageStock(_ game: SyncGameInput, page: String, stage: String) async throws {
        let desktop = DesktopFile(data: game.desktopData)
        guard !desktop.exec.isEmpty else { throw SyncPlanError.invalidInput("Stock game metadata is incomplete: \(game.name)") }
        let original = consoleType.originalGamesPath
        let arguments = try LaunchCommand.arguments(in: desktop.exec)
        let roms = arguments.filter { $0.hasPrefix(original + "/" + game.code + "/") }
        guard roms.count == 1, let rom = roms.first else { throw SyncPlanError.unsafeCommand }
        desktop.exec = try LaunchCommand.replacingROM(in: desktop.exec, oldPath: rom, newPath: "/var/squashfs" + rom)
        desktop.code = game.code
        desktop.iconPath = "/var/squashfs" + original
        desktop.iconFilename = game.code + ".png"
        try await upload([game.code + "/" + game.code + ".desktop": desktop.toData()], to: page, stage: stage)
        for folder in ["autoplay", "pixelart"] {
            let source = "/var/squashfs" + original + "/" + game.code + "/" + folder
            _ = try await shell.executeChecked("ln -sfn \(q(source)) \(q(page + "/" + game.code + "/" + folder))")
        }
    }

    private func stageCustom(_ game: SyncGameInput, page: String, stage: String, final: String) async throws {
        guard let directory = game.localDirectory, let filename = game.romFilename else { throw SyncPlanError.missingFile(game.name) }
        let desktop = DesktopFile(data: game.desktopData)
        let oldROM = try LaunchCommand.romPath(in: desktop.exec, filename: filename)
        let remoteROM = final + "/.storage/" + game.code + "/" + filename
        desktop.exec = try LaunchCommand.replacingROM(in: desktop.exec, oldPath: oldROM, newPath: remoteROM)
        desktop.code = game.code; desktop.profilePath = "/var/saves"; desktop.omitProfilePathCode = false
        desktop.iconPath = final + "/.storage"; desktop.iconFilename = game.code + ".png"
        var files = try readFiles(in: directory, code: game.code)
        guard files[game.code + "/" + filename] != nil else { throw SyncPlanError.missingFile(filename) }
        guard files.values.reduce(Int64(0), { $0 + Int64($1.count) }) <= game.byteCount else {
            throw SyncPlanError.invalidInput("Game files changed after review. Prepare the sync again.")
        }
        let artURL = directory.appendingPathComponent(game.code + ".png")
        let art = (try? Data(contentsOf: artURL)) ?? Self.generatePlaceholderPNG()
        files[game.code + "/" + game.code + ".png"] = resizeCoverArt(data: art, width: consoleType.coverWidth, height: consoleType.coverHeight)
        files[game.code + "/" + game.code + "_small.png"] = resizeCoverArt(data: art, width: 40, height: 40)
        files[game.code + "/" + game.code + ".desktop"] = desktop.toData()
        guard files.values.reduce(Int64(0), { $0 + Int64($1.count) }) <= game.byteCount + 64 * 1024 else {
            throw SyncPlanError.invalidInput("Generated game assets exceed the reviewed staging budget.")
        }
        try await upload(files, to: stage + "/.storage", stage: stage)
        try await upload([game.code + "/" + game.code + ".desktop": desktop.toData()], to: page, stage: stage)
    }

    private func readFiles(in directory: URL, code: String) throws -> [String: Data] {
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw SyncPlanError.missingFile(directory.path) }
        for case let url as URL in enumerator {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw SyncPlanError.invalidInput("Linked files cannot be synced automatically: \(url.lastPathComponent)") }
            if properties.isRegularFile == true {
                let relative = String(url.path.dropFirst(directory.path.count + 1))
                if relative.hasSuffix(".desktop") || relative.hasSuffix(".png") { continue }
                files[code + "/" + relative] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private func stageNavigation(target: Int, name: String, in page: String, stage: String, back: Bool) async throws {
        let code = String(format: "CLV-S-%05d", target)
        let desktop = DesktopFile()
        desktop.code = code; desktop.name = name
        desktop.exec = "/bin/chmenu \(String(format: "%03d", target)) /var/games"
        desktop.profilePath = "/var/saves/FOLDER"; desktop.omitProfilePathCode = true
        desktop.iconPath = "/var/games"; desktop.iconFilename = code + ".png"
        desktop.sortName = (back ? "Я" : "Ю") + name
        desktop.publisher = "ZZZZZZZZZZ"; desktop.testId = 777
        try await upload([
            code + "/" + code + ".desktop": desktop.toData(),
            code + "/" + code + ".png": back ? Self.generateBackPNG() : Self.generateFolderPNG(),
            code + "/" + code + "_small.png": back ? Self.generateBackSmallPNG() : Self.generateFolderSmallPNG()
        ], to: page, stage: stage)
    }

    private func upload(_ files: [String: Data], to directory: String, stage: String) async throws {
        var tar = TarWriter()
        let directories = Set(files.keys.flatMap { path -> [String] in
            let pieces = path.split(separator: "/").dropLast()
            return (1...max(1, pieces.count)).compactMap { count in pieces.isEmpty ? nil : pieces.prefix(count).joined(separator: "/") }
        })
        for name in directories.sorted() { tar.addDirectory(name: name) }
        for name in files.keys.sorted() {
            guard name.utf8.count < 100, !name.contains("\\"),
                  !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw SyncPlanError.invalidInput("A game filename cannot be represented safely: \(name)")
            }
            let data = files[name]!
            tar.addFile(name: name, contents: data)
            let relative = String(directory.dropFirst(stage.count + 1))
            checksums[(relative.isEmpty ? "" : relative + "/") + name] = BackupManifest.digest(data)
        }
        try await shell.uploadTar(data: tar.finalize(), to: directory, extraArgs: "", timeout: 300_000)
    }
    private func q(_ value: String) -> String { LaunchCommand.shellQuote(value) }

    // MARK: - Icon Assets

    /// 204x204 folder icon (from upstream hakchi2-CE folder_images/folder.png)
    private static let folderPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAMwAAADMBAMAAADNDFHBAAAAFVBMVEUAAAC6zNwAAABqgZiPqcXM3e2muMmI6FEdAAAAAXRSTlMAQObYZgAAAQRJREFUeF7s0rENwCAMRNGISdCxQcwEkTMC+6+SMhKycJEiBf8t8Iu74ycAAAAAAABA0aySSajZ7BSZlSKLaK2SSX0Zj8xL0rYZNYt1T023JuP3SPmlDTOS4kz38bBbBycAwlAQRMUOAhYQFhsx/AYE038rHj0FZXMR/kwD77bsWV7rV6gmY1bFuPKlLSSlYrRHHzcCYIoRjBEMjDGdx5QSTQ4DU5c8DAwMDAwMzHNu/FsD433BLAwMDAwMDMz8uYkmGO8L/pSBgYGBgbnbrWMaAAEgCIIXlJAXgxT8S6CkJV9yMwa23e+Z696pzLxzszPTm8kxa0lrJpmdMwWZXwAAAACABwuNRQpX1urdAAAAAElFTkSuQmCC"

    /// 204x204 back-arrow folder icon (from upstream hakchi2-CE folder_images/folder_back.png)
    private static let folderBackPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAMwAAADMBAMAAADNDFHBAAAAFVBMVEUAAAC6zNxqgZgAAACPqcXM3e2muMlbvZH3AAAAAXRSTlMAQObYZgAAAUJJREFUeF7szTENACAQBDASnIABwvn3xv4DjCytgbZPAAAAAKCnWpqH7FHNaG4Oe3aQgjAMRGEY8AQteoAMdV98XkA6HsBi7n8VFYQQk3EMdpf3r8zqA57IgDtILXxvJuPWPB4Za7xuGZwMYFI3zGSy9BrddEGHDIA6M2m8DW7xrpg7Y3ZQu+GX9gqgKwZnjXYWQGZojwwZMnab/nRe/lJ0AZmPJPhMdguQGaWVISPSyJAZpZUhI6kSI2MPU0pk7ONGallnDZk0TFmwb0Eyh+gzZIriKu53mow3j8+QSfMc46vVZ8ikecL78zMyxXFjzBOyZ3nWkKnME7KnfQuSSX35C4eM3dYMGTJkHu3WMQ0AIAwAwSYYIqkHpOBfAiMzHemdgV//KbN2TcvMnZuazL6ZGFkW0S1zZc2MBpkvAAAAAMABQrKSLHruDJ4AAAAASUVORK5CYII="

    /// 40x40 small folder icon (exact bytes from .NET hakchi2-CE sync)
    private static let folderSmallPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAM0SURBVFhH7ZZbSFNhAMe/HdeyixD0kIkWpUjWEitNI2ZqBUbSjcQKe+ghs4tW3oOsrJZYloWZiklaGnkBLShctU1NU7B5mVOXpc42y6R6qIje/vEt8uEzTme6CcH5we9hsO3/4zucwyFEREREREQocwghLn9xLvvFaUcikYXIA4KHfYM2jq0MDB3XNyhsTB4YMkI4biv7m+lk6ZrgrV9Tb1QhMbscCVfKxqWfk3MeYOOuAz88vFa0eHgu/6eLvOQt7ku81YQQT3ZoUshks0I2Rx60Bh3JKJjg0fOFiFPexrGLxYi7dAdxSn7jM0sQn1kK/9AdA7LZLunsns3Mm7+gLvZsHg6fy8ehM3kTjEnPRbyyGCVP2lHdaERlfS+vFdpeVDUY8ajVhOtldfCUB9xkN4Wy1MdvfXPQpp0/kq7eR8LlezjJmnXXehoFta1oMY7ihcEs2KYeCzrN35FZVAPCzcglhMxmA/hwU4TvHnqu/4j63jHUvTLxqtIN4emrt1C1vbHJRoMZuRVqcE4zQAhZxkbwIY+KSUWb6Ru0XSZoO4d4VbcPWgNt9YXBglvV9X8CvdkIPhYqwiN7aptfQ93x+3Ts7TPdALR6C05k3ICEc7L5BCnp2aWP0WiwTPhze0hPXdVhwQp/BY0rJ4TMYgN44aTOypyyOocGPu2wYNX6zTTQ9scNJ3XOvlmpcVygbgCa7lH4B2+hgUp2/59Ipc6xp3NKf9Z3W/DsLwNTVdtpQqWmG96+ATTwGrsvBG6NYss7ehkme5fy2dQ3ipMX8mjcZ0LIWnZcCLKAkAizIwOTLhXQwGF2WCgzA8O2jar1HxwS2Gz8iLTLxTTQTLfYcSHIVivCux4290Nj52chfQY2GN4jNi2LBn4hhDiz44KQSCTRyZmF1svBjkxFeoNUN/TBbbE3DSwmhDix20LZk6jMd1igq7snDdzOjtpCdEpWEV6+HsPz9kG72aAfRk1T/58T3MeO2kLk8YxcNBo/QaUbhkpH31ymrkY/ggeaHrh6WE/wADtqCzIfv3VX9x4+Bfp2ExWTYhf3x51BUFgEOI77NNlnIEsWIaTJAW5gh0RERERE/jN+AcIQNYTWe2OnAAAAAElFTkSuQmCC"

    /// 40x40 small back-arrow folder icon (exact bytes from .NET hakchi2-CE sync)
    private static let folderBackSmallPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAARcSURBVFhH7ZZ7TFNXHMdPL9ihm8mS/TFnZMvEkDk74iYMFlOGOBOMZq+MqItmcROGU9h8IE6BjkklOJBhKW8mCE4sqEAmg0GfFmHR0lIeghu2haJInH9si9l/3+UcA5mnXR9uM1nST/JNc2/P7e/T37nn3EtIgAABAgTwlccJIQvd5Al+4CNHJBLHSaJiHRExa2deil4zl4iY+BlJdNwUEYQN/DWPkqWrYjf8mlHchH0Fp7H3q4a50OP0okasfXf7vdBlK3pDw170mmeXSXqXPB+uJoSE8YUeCrF4fty6xCQm9ElOuUt2fVmBVHk1dufWIPXoSaTKPSctrxZpeXWIXPP2uHjBwiy+nt88+dTTHSkyJXZ+UYaPs5UuSc5SIE1eg9r2fjQbRqHSjXjMWe0ImvSjaOuz4+uGDoRJokr4mr6ydPnK1T0xb7xzb3/ht9h7rB57+OSfYt0ob+lD7+g0Lg1N+hzjsBOWyd+RV3UBRJinIIQs4AU8sVia8J6t23obupEZdFy1e0ynyYYfrv6Mzis/+RXD0CQUZ9UQguaBEPICL+EJyabkDFyx/wbtgB1ai81j1P03mKC/uTTkRGmzblYwnJfwxDPShMThlp4xqM33u+MtdFy3H6JdpnForU58llMMkRDkdwcpWQV1F2EYcrr8OB+91YGG73/Eye8uQ2Oxu3zvLrTrnWYnVkRKqdxpQsh8XsAjQnCIvKihw6ugzuqASm1mK7r8nA69Y7fYbcGP48NuC7MTL69eRwX9326E4JCCEpXGo6DeOsHkUnMr8eGhYuRVt6C6xYD69j5oLXaPU642jUMzOI3I2PVUUM7X90pwcEhKZlHdH7pBJ7rcFNCYbVB19yMttwrJWSVsw07OVjLRFFkZZEoV2ozDbBx/LQ39AyrNIMIjoqjgcb6+LwirpOsn6DTwq5R2ptU4jN1HKrHjsAK7uKcL3dSpaEZhPdtO3HXSeG0ae44oqdwvhJBX+eK+II6K2zjpTpB10GJH5XkDdmQqkCIrvd/BLCU+OnQCSZklTDQpU4GKczq3C4cK7j9aTgUdfGFfeSw6/s1ptfWWW0FWZGQKNa1GJkmn+XDxGRTUXoSsRMVEP8g4jmxFI5tO/tqe0ds4eKyGCk7SWnxxXxC/Ik0YaO25/rf30ZxkixHb0gvxTZsR/ba7rGPndVYUnGpH5okzbDP/6zV0D9QP3UTKwXwqeJcQEsIX9wmRSLQ1Pa+CTQcv9qDkTZQ2aVHapIHGYmMC9DGmHXCgSWNBl+nB8bSjzfprWPxcOBWsIYQE8bV9ZfM+eZlXQRqddcLlHF39ugGHy/lZwUVLwqjgW3xRf9h6IL8Kl8dm2Er0FrWZfo5z5/njG+zJc8F4fbaD7/NF/SHx0xwFDKN30GlyoNNE31z+eTTWKTRqhrEolHVwO1/UH8TLV75WuGXn56BvN5uSD/wr2ZaajZj4jRAE4c7D7oE8+YQQ43+Q1/lCAQIECBDgf8afSt0RpW4ujs4AAAAASUVORK5CYII="

    /// Folder icon PNG data
    private static func generateFolderPNG() -> Data {
        Data(base64Encoded: folderPNGBase64) ?? Data()
    }

    /// Back-arrow folder icon PNG data
    private static func generateBackPNG() -> Data {
        Data(base64Encoded: folderBackPNGBase64) ?? Data()
    }

    /// 40x40 small folder icon
    private static func generateFolderSmallPNG() -> Data {
        Data(base64Encoded: folderSmallPNGBase64) ?? Data()
    }

    /// 40x40 small back-arrow folder icon
    private static func generateBackSmallPNG() -> Data {
        Data(base64Encoded: folderBackSmallPNGBase64) ?? Data()
    }

    /// 40x40 gray placeholder for custom games without icons
    private static func generatePlaceholderPNG() -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 40, height: 40,
            bitsPerComponent: 8, bytesPerRow: 40 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }

        context.setFillColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        guard let image = context.makeImage() else { return Data() }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return data as Data
    }
}
