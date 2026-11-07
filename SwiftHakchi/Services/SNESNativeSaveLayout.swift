import Foundation

/// Conservative grouping of observed native SNES save formats. Unknown layouts
/// require separate review; this type does not grant permission to write.
struct SNESNativeSaveLayout: Sendable {
    enum Kind: Sendable { case cartridge, systemSave, suspendPoint(Int) }
    struct Group: Sendable { let gameCode: String, kind: Kind, paths: [String] }
    let groups: [Group]
    let gameCodes: Set<String>

    init(paths: [String]) throws {
        guard !paths.isEmpty, paths.count <= 4096, Set(paths).count == paths.count else { throw SNESLibraryInventory.failure() }
        var games: [String: Set<String>] = [:]
        for path in paths {
            guard SNESLibraryInventory.safePath(path) else { throw SNESLibraryInventory.failure() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5, Array(parts.prefix(3)) == ["clover", "profiles", "0"],
                  parts[3].range(of: #"^CLV-[PUS]-[A-Z0-9]{5}$"#, options: .regularExpression) != nil else {
                throw SNESLibraryInventory.failure()
            }
            games[parts[3], default: []].insert(parts.dropFirst(4).joined(separator: "/"))
        }
        var groups: [Group] = []
        for code in games.keys.sorted() {
            guard var remaining = games[code] else { throw SNESLibraryInventory.failure() }
            let prefix = "clover/profiles/0/\(code)/"
            func appendPair(_ members: Set<String>, kind: Kind) throws {
                let present = members.intersection(remaining)
                guard present.isEmpty || present == members else { throw SNESLibraryInventory.failure() }
                if !present.isEmpty {
                    groups.append(.init(gameCode: code, kind: kind, paths: present.sorted().map { prefix + $0 }))
                    remaining.subtract(present)
                }
            }
            try appendPair(["cartridge.sram", "cartridge.sram.hash"], kind: .cartridge)
            try appendPair(["save/system-save.json/data", "save/system-save.json/hash"], kind: .systemSave)
            for slot in 1...4 {
                let base = "suspendpoint\(slot)/", members = Set(remaining.filter { $0.hasPrefix(base) })
                guard !members.isEmpty else { continue }
                let required: Set<String> = [base + "state.png", base + "state.time", base + "rollback/sram.hash"]
                guard required.isSubset(of: members) else { throw SNESLibraryInventory.failure() }
                var breaks = Set<Int>(), inputs = Set<Int>()
                for name in members.subtracting(required) {
                    let stem = base + "rollback/"
                    guard name.hasPrefix(stem) else { throw SNESLibraryInventory.failure() }
                    let value = String(name.dropFirst(stem.count)).split(separator: ".", omittingEmptySubsequences: false)
                    guard value.count == 2, let index = Int(value[0]), (0...255).contains(index), String(index) == value[0] else {
                        throw SNESLibraryInventory.failure()
                    }
                    if value[1] == "break" { breaks.insert(index) }
                    else if value[1] == "inputs" { inputs.insert(index) }
                    else { throw SNESLibraryInventory.failure() }
                }
                guard let last = breaks.max(), breaks == Set(0...last), inputs == breaks.subtracting([last]) else {
                    throw SNESLibraryInventory.failure()
                }
                groups.append(.init(gameCode: code, kind: .suspendPoint(slot), paths: members.sorted().map { prefix + $0 }))
                remaining.subtract(members)
            }
            guard remaining.isEmpty else { throw RecoveryProbeError.refused("Some saved files use a format that needs a separate review. Nothing was copied.") }
        }
        self.groups = groups; gameCodes = Set(games.keys)
    }
}
