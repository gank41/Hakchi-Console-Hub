import Foundation
import SwiftHakchiCore

struct DeviceInventory: Sendable {
    let profile: ConsoleProfile
    let consoleType: ConsoleType
    let activePage: String
    let syncBase: String?
    let freeBytes: Int64
    let installedCodes: Set<String>
    let visibleCodes: Set<String>
    let versions: String
    let canSync: Bool

    var originalGamesPath: String { consoleType.originalGamesPath }
}

enum DeviceInventoryService {
    enum Command {
        static let identity = "hakchi hwid 2>/dev/null || cat /etc/clover/uid"
        static let system = "cat /etc/clover/system_code 2>/dev/null || hakchi eval 'echo \"$sftype-$sfregion\"'"
        static let activePage = "readlink -f /var/games"
        static let capacity = "df -Pk /var/lib/hakchi/games"
        static let version = "source /var/version && printf '%s %s %s' \"$bootVersion\" \"$kernelVersion\" \"$hakchiVersion\""
    }

    static func inspect(shell: any ConsoleShell) async throws -> DeviceInventory {
        let identity = try await shell.executeChecked(Command.identity).output.filter { !$0.isWhitespace }
        let system = try await shell.executeChecked(Command.system).output
        let type = ConsoleType.fromSystemCode(system)
        let activeResult = try await shell.execute(Command.activePage, timeout: 30_000)
        let active = activeResult.succeeded ? activeResult.output : ""
        let capacity = try await shell.executeChecked(Command.capacity).output
        guard let line = capacity.split(separator: "\n").last else { throw SyncPlanError.invalidInput("Could not measure console storage.") }
        let columns = line.split(whereSeparator: \.isWhitespace)
        guard columns.count >= 4, let blocks = Int64(columns[3]), blocks >= 0,
              blocks <= Int64.max / 1024 else { throw SyncPlanError.invalidInput("Could not measure console storage.") }
        let versionResult = try await shell.execute(Command.version, timeout: 30_000)
        let version = versionResult.succeeded ? versionResult.output : ""
        let versionParts = version.split(separator: " ").map(String.init)
        let compatibleVersions = versionParts.count == 3
            && VersionTuple.parse(versionParts[0]) >= VersionTuple(1, 0, 2)
            && VersionTuple.parse(versionParts[1]) >= VersionTuple(3, 4, 113)
            && VersionTuple.parse(versionParts[2]) >= VersionTuple(1, 0, 4, 118)
        let profile = ConsoleProfile(deviceID: identity, systemCode: type.syncCode)
        let expectedBase = "/var/lib/hakchi/games/\(type.syncCode)"
        let components = active.split(separator: "/")
        let page = components.last.map(String.init) ?? ""
        let matchesLayout = active.hasPrefix(expectedBase + "/")
            && String(active.dropLast(page.count + 1)) == expectedBase
            && page.count == 3 && page.allSatisfy(\.isNumber)
        let base = matchesLayout ? expectedBase : nil
        var installed = Set<String>()
        var visible = Set<String>()
        if let base {
            let storage = LaunchCommand.shellQuote(base + "/.storage")
            let result = try await shell.execute("find \(storage) -mindepth 1 -maxdepth 1 -type d -exec basename '{}' ';'", timeout: 30_000)
            guard result.succeeded else { throw SyncPlanError.invalidInput("Could not read the installed game inventory.") }
            let codes = result.output.split(whereSeparator: \.isNewline).map(String.init)
            guard codes.allSatisfy(SyncPlanner.validCode) else { throw SyncPlanError.invalidInput("The console contains unrecognized game identifiers.") }
            installed = Set(codes)
            let menus = try await shell.executeChecked("find \(LaunchCommand.shellQuote(base)) -mindepth 2 -maxdepth 2 -name 'CLV-*' ! -path '*/.storage/*' -exec basename '{}' ';'")
            let menuCodes = menus.output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("CLV-S-") }
            guard menuCodes.allSatisfy(SyncPlanner.validCode) else { throw SyncPlanError.invalidInput("The console menu contains unrecognized game identifiers.") }
            visible = Set(menuCodes)
        }
        let validIdentity = identity.range(of: #"^[A-Za-z0-9:_-]+$"#, options: .regularExpression) != nil
        return DeviceInventory(profile: profile, consoleType: type, activePage: active, syncBase: base,
            freeBytes: blocks * 1024, installedCodes: installed, visibleCodes: visible, versions: version,
            canSync: validIdentity && profile.supportsGameSync && matchesLayout && compatibleVersions)
    }
}
