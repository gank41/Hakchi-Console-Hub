import Foundation

/// Keeps the reviewed immutable bytes and checks source identity across awaits. No console authority.
struct SNESLibraryMaterialGuard: Sendable {
    let material: SNESLibraryMaterial
    private let names: [String], seals: [SNESFirmwareSourceSeal]
    private init(material: SNESLibraryMaterial, names: [String], seals: [SNESFirmwareSourceSeal]) {
        self.material = material; self.names = names; self.seals = seals
    }
    static func prepare(_ material: SNESLibraryMaterial, sourcePolicy: SNESLibrarySourcePolicy = .live) throws -> Self {
        try prepare(material, sourcePolicy: sourcePolicy, candidateOnly: false)
    }
    /// Offline review only; this does not make a candidate eligible for sync.
    static func prepareCompatibilityCandidate(_ material: SNESLibraryMaterial) throws -> Self {
        try prepare(material, sourcePolicy: .live, candidateOnly: true)
    }
    private static func prepare(_ material: SNESLibraryMaterial, sourcePolicy: SNESLibrarySourcePolicy, candidateOnly: Bool) throws -> Self {
        func validate() throws {
            try material.menu.validate()
            let loaded: SNESLibraryMaterial
            if candidateOnly {
                loaded = try SNESLibraryMaterial.loadCompatibilityCandidate(directory: material.directory, expectedReviewSHA256: material.reviewSHA256)
            } else {
                loaded = try SNESLibraryMaterial.load(directory: material.directory, expectedReviewSHA256: material.reviewSHA256, sourcePolicy: sourcePolicy)
            }
            guard loaded.menu.manifest == material.menu.manifest,
                  loaded.menu.sourceSHA256 == material.menu.sourceSHA256,
                  loaded.menu.files == material.menu.files,
                  loaded.menu.objects == material.menu.objects else { throw SNESLibraryMenu.failure() }
        }
        try validate()
        let directory = try RestoreDirectory(material.directory), names = try directory.names()
        var seen = Set<URL>()
        let liveSources = sourcePolicy == .live ? material.menu.sources : []
        let paths = (names.map { directory.url.appendingPathComponent($0) } + liveSources.map {
            URL(fileURLWithPath: $0.directory).appendingPathComponent($0.name)
        }).filter { seen.insert($0).inserted }
        guard paths.count <= 4096 else { throw SNESLibraryMenu.failure() }
        var seals: [SNESFirmwareSourceSeal] = []
        for start in stride(from: 0, to: paths.count, by: 16) {
            seals.append(try .capture(directories: [], files: Array(paths[start..<min(start+16, paths.count)])))
        }
        // Check bytes after sealing; subsequent calls use identity checks rather than rehashing the whole library.
        try validate()
        let result = Self(material: material, names: names, seals: seals); try result.require(); return result
    }
    func require() throws {
        try Task.checkCancellation()
        let directory = try RestoreDirectory(material.directory)
        guard try directory.names() == names else { throw SNESLibraryMenu.failure() }
        for seal in seals { try seal.validate() }
        try directory.check()
        guard try directory.names() == names else { throw SNESLibraryMenu.failure() }
    }
}
