import Foundation
import CryptoKit

@MainActor
enum GameGenieWorkflow {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func readROM(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 8 * 1024 * 1024 else { throw GameGenieError.unsupportedROM }
        return try Data(contentsOf: url)
    }
    /// Identifies a managed source without claiming it can be patched.
    static func managedSourceDigest(game: Game, manager: GameManagerService) throws -> String {
        guard game.source == .local, !game.isCheatCodeCopy else { throw GameGenieError.unsupportedROM }
        let target = try GameArtworkTarget(game: game, gamesDirectory: AppConfig.shared.gamesDirectory)
        try manager.validateArtworkTarget(target)
        let files = try FileManager.default.contentsOfDirectory(at: target.folder, includingPropertiesForKeys: nil)
            .filter { ["nes", "fds", "sfc", "smc", "sfrom", "md", "gen", "bin", "smd"].contains($0.pathExtension.lowercased()) }
        guard files.count == 1, let rom = files.first else { throw GameGenieError.unsupportedROM }
        return digest(try readROM(rom))
    }
    static func open(game: Game, manager: GameManagerService) throws -> GameGenieSession {
        guard let system=GameGenieSystem(console:game.consoleType) else { throw GameGenieError.unsupportedROM }
        let config = AppConfig.shared
        let target = try GameArtworkTarget(game: game, gamesDirectory: config.gamesDirectory)
        try manager.validateArtworkTarget(target)
        if let binding = try GameGenieVariantStore.binding(for: game, manager: manager) {
            guard let original = manager.games.first(where: { $0.code == binding.sourceCode }),
                  original.source == .local else { throw GameGenieError.changedROM }
            let originalTarget = try GameArtworkTarget(game: original, gamesDirectory: config.gamesDirectory)
            guard !FileManager.default.fileExists(atPath: originalTarget.folder.appendingPathComponent(GameGenieVariantStore.bindingFilename).path) else { throw GameGenieError.changedROM }
            let opened = try open(game: original, manager: manager)
            guard opened.sha256 == binding.sourceSHA256 else { throw GameGenieError.changedROM }
            return opened
        }
        let files = try FileManager.default.contentsOfDirectory(at: target.folder, includingPropertiesForKeys: nil)
            .filter { ["nes", "fds", "sfc", "smc", "sfrom", "md", "gen", "bin", "smd"].contains($0.pathExtension.lowercased()) }
        guard files.count == 1, let rom = files.first else { throw GameGenieError.unsupportedROM }
        let bytes = try readROM(rom); try GameGenieROMPatcher.validate(data:bytes,system:system,extension:rom.pathExtension)
        return GameGenieSession(target: target, romURL: rom, sha256: digest(bytes), workspace: config.workspace.root, system:system)
    }
}

@MainActor
struct GameGenieSession {
    let target: GameArtworkTarget
    let romURL: URL
    let sha256: String
    let workspace: URL
    var system:GameGenieSystem = .nes
    /// Check every destination component, including existing parents, before writing.
    private func directory(_ components: [String], create: Bool) throws -> URL? {
        var current = workspace
        for component in [""] + components {
            if !component.isEmpty { current.appendPathComponent(component, isDirectory: true) }
            let values = try? current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { throw GameGenieError.unsafeDestination }
            if !FileManager.default.fileExists(atPath: current.path) {
                guard create else { return nil }
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            let checked = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard checked.isDirectory == true, checked.isSymbolicLink != true else { throw GameGenieError.unsafeDestination }
        }
        return current
    }
    private func profileURL(create: Bool) throws -> URL? {
        try directory(["Library", "Cheats", target.gamesDirectory.lastPathComponent, target.code], create: create)?
            .appendingPathComponent(sha256 + ".json")
    }
    private func readProfile(at url: URL) throws -> GameGenieProfile {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= GameGenieProfile.maximumStoredBytes else { throw GameGenieError.invalidProfile }
        return try JSONDecoder().decode(GameGenieProfile.self, from: Data(contentsOf: url))
    }
    func loadProfile() throws -> GameGenieProfile {
        if let url = try profileURL(create: false), FileManager.default.fileExists(atPath: url.path) {
            let profile = try readProfile(at: url); try profile.validate(sha256: sha256); guard profile.codeSystem==system else {throw GameGenieError.invalidProfile}; return profile
        }
        // Retain early preview profiles. Only reuse one for the exact same full-file SHA.
        if let parent = try directory(["Library", "Cheats", target.gamesDirectory.lastPathComponent], create: false) {
            let legacy = parent.appendingPathComponent(target.code + ".json")
            if FileManager.default.fileExists(atPath: legacy.path) {
                let profile = try readProfile(at: legacy)
                if profile.romSHA256 == sha256 { try profile.validate(sha256: sha256); guard profile.codeSystem==system else {throw GameGenieError.invalidProfile}; return profile }
            }
        }
        return GameGenieProfile(system:system == .nes ? nil:system,romSHA256: sha256)
    }
    func source(manager: GameManagerService) throws -> Data {
        guard AppConfig.shared.workspace.root.standardizedFileURL == workspace.standardizedFileURL else { throw GameGenieError.changedROM }
        try manager.validateArtworkTarget(target)
        let data = try GameGenieWorkflow.readROM(romURL)
        guard GameGenieWorkflow.digest(data) == sha256 else { throw GameGenieError.changedROM }
        return data
    }
    func saveProfile(_ profile: GameGenieProfile, manager: GameManagerService) throws {
        _ = try source(manager: manager); try profile.validate(sha256: sha256); guard profile.codeSystem==system else {throw GameGenieError.invalidProfile}
        let data = try profile.encodedForStorage()
        guard let url = try profileURL(create: true) else { throw GameGenieError.unsafeDestination }
        if FileManager.default.fileExists(atPath: url.path) { _ = try readProfile(at: url) }
        try data.write(to: url, options: .atomic)
    }
    func preview(_ profile: GameGenieProfile, manager: GameManagerService) throws -> NESGameGeniePatcher.Result {
        try profile.validate(sha256: sha256); guard profile.codeSystem==system else {throw GameGenieError.invalidProfile}
        _ = try profile.encodedForStorage()
        return try GameGenieROMPatcher.patch(data: source(manager: manager),system:system,extension:romURL.pathExtension,codes:profile.enabledCodes)
    }
    /// Runtime cheat data only: no ROM patching, installation or launch-command changes.
    func exportRetroArch(_ profile: GameGenieProfile, manager: GameManagerService) throws -> URL {
        _ = try source(manager: manager)
        try profile.validate(sha256: sha256); guard profile.codeSystem==system else {throw GameGenieError.invalidProfile}
        _ = try profile.encodedForStorage()
        guard system == .nes else {throw GameGenieError.unsupportedROM}
        let content = try RetroArchCheatFile.encode(profile: profile)
        guard let folder = try directory(["Exports", "RetroArch-Cheats", UUID().uuidString], create: true) else { throw GameGenieError.unsafeDestination }
        let destination = folder.appendingPathComponent(target.code + ".cht")
        struct Manifest: Encodable {
            let format = "NES emulator-handled cheats for a compatible FCEUmm/RetroArch runtime; installed version must be validated"
            let allEffectsInitiallyDisabled = true
            let sourceROM: String
            let sourceSHA256: String
            let cheatSHA256: String
            let profile: GameGenieProfile
        }
        let guide = """
        NES CLASSIC RUNTIME CHEAT PREPARATION

        This package contains no ROM and installs nothing on the console.
        It requires a compatible, validated RetroArch + FCEUmm runtime.
        The current Mac app does not yet install that runtime or this file.

        1. Deploy this .cht to the installed runtime's verified, persistent cheat directory.
        2. Launch the exact ROM named in manifest.json using FCEUmm.
        3. Open the in-game RetroArch menu. The original Classic port documents Select+Start;
           verify the installed version's controller configuration first.
        4. Quick Menu > Cheats > Load Cheat File (Replace), then choose this .cht.
        5. Enable named effects, select Apply Changes, then Resume.
        6. To disable, turn effects off and Apply Changes again.

        All exported entries start OFF; desktop patch selections do not change that policy.
        '+' joins all codes of a single named effect. Some start/lives/event codes only act
        after a restart or reaching an event. Turning a cheat off does not undo earlier
        changes to lives, inventory, scores or saves. Preserve your saves before testing.
        Mutually exclusive effects (such as different starting-life counts) must not be
        enabled together. Decode success is not proof of ROM-region/revision compatibility.
        Read catalog notes before selecting a code. SNES is a separate core-specific workflow.

        Documentation: https://docs.libretro.com/guides/cheat-codes/
        Classic reference: https://github.com/ClusterM/retroarch-clover
        """
        do {
            try content.write(to: destination, options: .withoutOverwriting)
            let manifest = Manifest(sourceROM: romURL.lastPathComponent, sourceSHA256: sha256,
                                    cheatSHA256: GameGenieWorkflow.digest(content), profile: profile)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
            try Data(guide.utf8).write(to: folder.appendingPathComponent("READ-ME.txt"), options: .withoutOverwriting)
            return destination
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    func export(_ profile: GameGenieProfile, manager: GameManagerService) throws -> URL {
        let result = try preview(profile, manager: manager)
        guard let folder = try directory(["Exports", "CheatCodes", UUID().uuidString], create: true) else { throw GameGenieError.unsafeDestination }
        let destination = folder.appendingPathComponent(target.code + "-CheatCodes." + romURL.pathExtension.lowercased())
        struct Manifest: Encodable {
            let originalSHA256: String
            let patchedSHA256: String
            let patchedFile: String
            let writtenOffsets: [Int]
            let profile: GameGenieProfile
        }
        do {
            try result.data.write(to: destination, options: .withoutOverwriting)
            let manifest = Manifest(originalSHA256: sha256, patchedSHA256: GameGenieWorkflow.digest(result.data), patchedFile: destination.lastPathComponent,
                                    writtenOffsets: result.offsets, profile: profile)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
            return destination
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
