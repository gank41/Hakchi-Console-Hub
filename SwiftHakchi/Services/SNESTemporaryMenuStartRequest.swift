import Foundation

/// One fixed RAM-only startup action, deliberately separate from read-only requests.
/// Carries the sealed recipe; the client revalidates it before sending any command.
struct SNESTemporaryMenuStartRequest: Sendable {
    private let menu: PreparedSNESTemporaryMenu
    let challenge: UUID
    init(menu: PreparedSNESTemporaryMenu, challenge: UUID) { self.menu = menu; self.challenge = challenge }
    func validateCurrent() throws { try menu.validateCurrent() }
    var command: String { Self.command(for: challenge) }
    static func command(for challenge: UUID) -> String { "exec /probe/busybox sh /probe/start " + challenge.uuidString }
}
