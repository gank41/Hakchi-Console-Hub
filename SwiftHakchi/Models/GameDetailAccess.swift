/// Editing and downloading are separate capabilities: a remote game can be
/// downloadable even when its metadata is shown read only.
struct GameDetailAccess {
    let source: GameSource
    let hasSSH: Bool
    let isLegacyInspection: Bool
    var canEditMetadata: Bool { source == .local && !isLegacyInspection }
    var canDownloadROM: Bool { hasSSH && !isLegacyInspection }
}
