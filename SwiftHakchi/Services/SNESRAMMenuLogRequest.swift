import Foundation

enum SNESRAMMenuLogRequest {
    static func parse(_ arguments: [String]) throws -> UUID? {
        guard arguments.first == "--read-snes-ram-menu-logs" else { return nil }
        guard arguments.count == 2, let nonce = UUID(uuidString: arguments[1]), nonce.uuidString == arguments[1] else {
            throw RecoveryProbeError.refused("The temporary menu log request needs its exact test nonce. No console command was sent.")
        }
        return nonce
    }
}
