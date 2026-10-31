import Foundation

struct SNESTemporaryMenuExpectation: Sendable {
    let binding: SNESRuntimeBinding, nonce: String, filesSHA256: String, sourceFilesSHA256: String
    func validate() throws {
        try binding.validate()
        guard UUID(uuidString: nonce)?.uuidString == nonce,
              [filesSHA256, sourceFilesSHA256].allSatisfy({ $0.count == 64 && SNESRuntimeBinding.hex($0) }) else { throw SNESRuntimeBinding.failure() }
    }
}
extension PreparedSNESTemporaryMenu {
    var expectation: SNESTemporaryMenuExpectation {
        .init(binding: binding, nonce: nonce, filesSHA256: filesSHA256, sourceFilesSHA256: sourceFilesSHA256)
    }
}
struct SNESTemporaryMenuReport: Sendable {
    let raw: Data, freeKiB: Int
    init(_ bytes: Data, expected: SNESTemporaryMenuExpectation, challenge: UUID) throws {
        try expected.validate()
        guard bytes.count <= 65536, bytes.allSatisfy({ $0 == 10 || (32...126).contains($0) }),
              let text = String(data: bytes, encoding: .ascii), text.hasSuffix("\n") else { throw SNESRuntimeBinding.failure() }
        let lines = text.dropLast().components(separatedBy: "\n")
        guard lines.first == "SWIFTHAKCHI_SNES_MENU_REPORT_V1", lines.last == "END", lines.count == 43,
              lines[23] == "MOUNTS_BEGIN", lines[41] == "MOUNTS_END" else { throw SNESRuntimeBinding.failure() }
        var fields: [String: String] = [:]
        for line in lines[1..<23] {
            guard let index = line.firstIndex(of: "=") else { throw SNESRuntimeBinding.failure() }
            let key = String(line[..<index]), value = String(line[line.index(after: index)...])
            guard fields[key] == nil else { throw SNESRuntimeBinding.failure() }
            fields[key] = value
        }
        let constants = ["NONCE": expected.nonce, "CHALLENGE": challenge.uuidString, "KERNEL": "3.4.112.madmonkey",
            "BOARD": "dp-shvc", "REGION": "USA", "HWID": expected.binding.expectedHWID,
            "FILES_SHA": expected.filesSHA256, "SOURCE_FILES_SHA": expected.sourceFilesSHA256,
            "STATUS": "ready", "BLOCKS": "readonly", "MODULES": "clovercon,mali,sunxi_keyboard,sunxi_knob",
            "CONTROLLER": "loaded-arguments:1,-1,2,-1;36;0;0;8;0", "BINDS": "verified", "DEVICES": "ready",
            "USB": "verified-hvc-0", "PROFILE": "temporary", "SUPERVISOR": "busybox-init"]
        guard Set(fields.keys) == Set(constants.keys).union(["TAINT", "MCP_PID", "DAEMON_PID", "FREE_KIB", "TOTAL_KIB"]),
              constants.allSatisfy({ fields[$0.key] == $0.value }), ["0", "4096"].contains(fields["TAINT"]),
              let mcp = Self.integer(fields["MCP_PID"]), mcp > 1, mcp <= 4_194_304,
              let daemon = Self.integer(fields["DAEMON_PID"]), daemon > 1, daemon <= 4_194_304, daemon != mcp,
              let total = Self.integer(fields["TOTAL_KIB"]), (1...1048576).contains(total),
              let free = Self.integer(fields["FREE_KIB"]), (0...total).contains(free) else { throw SNESRuntimeBinding.failure() }
        try Self.validateMounts(Array(lines[24..<41]))
        raw = bytes; freeKiB = free
    }
    private static func integer(_ text: String?) -> Int? {
        guard let text, let n = Int(text), String(n) == text else { return nil }; return n
    }
    static func validateMounts(_ lines: [String]) throws {
        var seen: Set<String> = []
        let sizes = ["/probe": "16384k", "/newroot/etc/udev/rules.d": "16384k", "/newroot/lib/udev/rules.d": "16384k", "/newroot/run/swifthakchi": "16384k", "/newroot/var": "32768k", "/newroot/run": "8192k", "/newroot/tmp": "16384k", "/newroot/dev/shm": "8192k"]
        for line in lines {
            let f = line.components(separatedBy: " ")
            guard f.count == 6, f[4] == "0", f[5] == "0", seen.insert(f[1]).inserted else { throw SNESRuntimeBinding.failure() }
            let options = f[3].components(separatedBy: ","), flags = Set(options)
            guard flags.count == options.count else { throw SNESRuntimeBinding.failure() }
            switch f[1] {
            case "/":
                guard f[0] == "rootfs", f[2] == "rootfs", flags.contains("rw"), !flags.contains("ro") else { throw SNESRuntimeBinding.failure() }
            case "/dev", "/newroot/dev": guard f[2] == "devtmpfs" else { throw SNESRuntimeBinding.failure() }
            case "/proc", "/newroot/proc": guard f[2] == "proc" else { throw SNESRuntimeBinding.failure() }
            case "/sys", "/newroot/sys": guard f[2] == "sysfs" else { throw SNESRuntimeBinding.failure() }
            case "/newroot":
                guard ["/dev/dm-0", "/dev/mapper/swifthakchi-probe-root"].contains(f[0]), f[2] == "squashfs",
                      flags.contains("ro"), !flags.contains("rw") else { throw SNESRuntimeBinding.failure() }
            case "/newroot/dev/pts":
                guard f[2] == "devpts", flags.isSuperset(of: ["nosuid", "noexec"]) else { throw SNESRuntimeBinding.failure() }
            default:
                guard let size = sizes[f[1]], f[0] == "tmpfs", f[2] == "tmpfs",
                      flags.isSuperset(of: ["rw", "nosuid", "nodev", "size=" + size]), !flags.contains("ro"),
                      options.filter({ $0.hasPrefix("size=") }) == ["size=" + size] else { throw SNESRuntimeBinding.failure() }
            }
        }
        guard seen == Set(["/", "/probe", "/dev", "/proc", "/sys", "/newroot", "/newroot/dev", "/newroot/proc", "/newroot/sys",
            "/newroot/var", "/newroot/run", "/newroot/tmp", "/newroot/dev/shm", "/newroot/dev/pts",
            "/newroot/etc/udev/rules.d", "/newroot/lib/udev/rules.d", "/newroot/run/swifthakchi"]) else { throw SNESRuntimeBinding.failure() }
    }
}
