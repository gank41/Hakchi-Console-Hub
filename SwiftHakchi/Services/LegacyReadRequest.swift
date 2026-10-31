import Foundation

/// Fixed read-only commands. No arbitrary command, upload or mutation API is exposed.
enum LegacyReadRequest: Sendable, Equatable {
    var maximumOutputBytes: Int {
        switch self {
        case .snesRAMProbeReport, .snesTemporaryMenuReport, .snesTemporaryMenuDiagnostics, .snesOriginalMenuReport, .snesOriginalMenuDiagnostics: return 65536
        case .snesAlienTrialReport: return 1024
        case .report: return 65536
        case .chipID, .consoleIdentity: return 1024
        case .metadata: return 16 * 1024 * 1024
        case .backup: return 512 * 1024 * 1024
        case .backupDigest: return 1024
        case .storageReport: return 65536
        }
    }
    var isBinary: Bool {
        if case .snesOriginalMenuReport = self { return true }
        if self == .snesOriginalMenuDiagnostics { return true }
        return self == .metadata || self == .backup
    }
    case report, chipID, metadata, backup, backupDigest, storageReport, consoleIdentity, snesRAMProbeReport
    case snesOriginalMenuReport(challenge: UUID), snesOriginalMenuDiagnostics
    case snesAlienTrialReport(challenge: UUID)
    case snesTemporaryMenuReport(challenge: UUID), snesTemporaryMenuDiagnostics
    var command: String {
        switch self {
        case .snesAlienTrialReport(let challenge): return "exec /probe/busybox sh /probe/trial-report " + challenge.uuidString
        case .snesOriginalMenuReport(let challenge): return "exec /probe/busybox sh /probe/report ready " + challenge.uuidString
        case .snesTemporaryMenuReport(let challenge): return "exec /probe/busybox sh /probe/report " + challenge.uuidString
        case .snesOriginalMenuDiagnostics: return "exec /probe/busybox sh /probe/diagnostics"
        case .snesTemporaryMenuDiagnostics:
            return "exec /probe/busybox sh /probe/diagnostics"
        case .snesRAMProbeReport: return "exec /probe/busybox sh /probe/report"
        case .consoleIdentity: return LegacyConsoleIdentity.command
        case .storageReport: return LegacyStorageReport.command
        case .report:
            return "set -e; printf '__VERSION__\\n'; cat /var/version; printf '__ACTIVE__\\n'; readlink -f /var/games; printf '__CAPACITY__\\n'; df -Pk /var/lib; printf '__SAVES__\\n'; readlink -f /var/saves; printf '__FACTORY__\\n'; find /var/squashfs/usr/share/games/nes/kachikachi -mindepth 1 -maxdepth 1 -type d -name 'CLV-*' -exec basename '{}' ';'; printf '__VISIBLE__\\n'; find /var/lib/hakchi/games/nes -mindepth 2 -maxdepth 2 -name 'CLV-*' -exec basename '{}' ';'; printf '__END__\\n'"
        case .chipID:
            return "set -e; printf 'SWIFTHAKCHI_CHIP_ID_V1\\n'; /bin/devmem 0x01c23800 32; /bin/devmem 0x01c23804 32; /bin/devmem 0x01c23808 32; /bin/devmem 0x01c2380c 32; printf 'END\\n'"
        case .metadata:
            return "set -o pipefail; cd /; find var/squashfs/usr/share/games/nes/kachikachi var/lib/hakchi/games/nes -type f -name '*.desktop' | tar -c -T -"
        case .backup, .backupDigest:
            let tar = "set -o pipefail; tar -c -C / var/lib/hakchi var/lib/clover/profiles/0 var/squashfs/usr/share/games/nes/kachikachi"
            return self == .backupDigest ? tar + " | sha256sum" : tar
        }
    }
}

protocol LegacyRequestExecuting: Sendable {
    func execute(_ request: LegacyReadRequest, timeoutMilliseconds: Int) async throws -> SSHResult
}
