import Foundation

/// Inert target data shared by exact cleanup and cancellation. Native adapters still require their distinct live journal permits.
protocol SNESLibraryRetirementScope: Sendable {
    var fileTargets: [SNESLibraryMenu.FileRecord] { get }
    var directories: [String] { get }
    var protectedMenus: [SNESLibraryInventory.Menu] { get }
    var hwid: String { get }
    var totalBytes: Int64 { get }
    var selection: SNESLibraryInventory.Selection { get }
    var reviewSHA256: String { get }
    var retiredRootPath: String { get }
    var unprotectedMenuID: UUID? { get }
    var retireNamespace: Bool { get }
    func validateSources() throws
}
extension SNESLibraryCleanupPlan: SNESLibraryRetirementScope {
    var fileTargets: [SNESLibraryMenu.FileRecord] { files.map { .init(path: $0.path, byteCount: $0.byteCount, sha256: $0.sha256) } }
    var retiredRootPath: String { oldMenuID.map { (oldMenuKind == .legacy ? "legacy/menus/" : "menus/") + $0.uuidString } ?? "" }
    var unprotectedMenuID: UUID? { oldMenuKind == .library ? oldMenuID : nil }
    var retireNamespace: Bool { false }
}
extension SNESLibraryDiscardPlan: SNESLibraryRetirementScope {
    var retiredRootPath: String { retireNamespace ? "namespace" : "menus/" + retiredMenuID.uuidString }
    var unprotectedMenuID: UUID? { retiredMenuID }
}
