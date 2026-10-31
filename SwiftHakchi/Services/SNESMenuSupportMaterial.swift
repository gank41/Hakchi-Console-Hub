import Foundation
import SwiftHakchiCore

/// File-only reconstruction of the accepted support capture; no editable flag grants boot access.
struct SNESMenuSupportMaterial: Sendable {
    let source: SNESMenuSupportSource, frame: SNESMenuSupportFrame, directoryURL: URL, manifestSHA256: String
    var setup: SNESOfflineSource { source.preparation.source.source }
    private struct Manifest: Decodable {
        let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
    }
    private init(source: SNESMenuSupportSource, frame: SNESMenuSupportFrame, url: URL, hash: String) {
        self.source = source; self.frame = frame; directoryURL = url; manifestSHA256 = hash
    }
    static func load(source: SNESMenuSupportSource, directory url: URL) throws -> Self {
        try source.revalidate()
        let directory = try RestoreDirectory(url), prefix = "SNES-Menu-Support-"
        guard directory.url.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESRuntimeBinding.failure() }
        let raw = try directory.read("manifest.json", maximum: 65536)
        let saved = try JSONDecoder().decode(Manifest.self, from: raw)
        let frame = try SNESMenuSupportFrame(directory.read("support.frame", maximum: SNESMenuSupportFrame.maximumSize))
        let result = SNESMenuSupportResult(source: source, frame: frame, before: saved.before, after: saved.after, observation: saved.observation)
        let checked = try result.checkedExport()
        guard let expected = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let actual = try JSONSerialization.jsonObject(with: checked.manifest) as? NSDictionary,
              actual.isEqual(to: expected) else { throw SNESRuntimeBinding.failure() }
        try directory.check()
        return Self(source: source, frame: frame, url: directory.url, hash: BackupManifest.digest(raw))
    }
    func revalidate() throws {
        let current = try Self.load(source: source, directory: directoryURL)
        guard current.manifestSHA256 == manifestSHA256, current.frame.raw == frame.raw else { throw SNESRuntimeBinding.failure() }
    }
    func requireRecipeInputs() throws {
        for (path, value) in [("etc/clover/ui", "snes-usa"), ("etc/clover/buildtype", "final")] {
            guard let r = frame.records.first(where: { $0.path == path }), r.kind == "F", let data = r.data,
                  String(data: data, encoding: .ascii)?.trimmingCharacters(in: .newlines) == value else { throw SNESRuntimeBinding.failure() }
        }
        for path in ["etc/asound.conf", "etc/nsswitch.conf", "etc/group", "etc/passwd", "etc/udev/udev.conf", "usr/bin/clover-canoe-shvc"] {
            guard let r = frame.records.first(where: { $0.path == path }), r.kind == "F", let data = r.data,
                  data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else { throw SNESRuntimeBinding.failure() }
        }
        for path in ["sbin/udevd", "usr/bin/udevadm", "usr/bin/clover-mcp"] {
            guard frame.records.contains(where: { $0.path == path && $0.kind == "B" && $0.count > 0 }) else { throw SNESRuntimeBinding.failure() }
        }
        guard frame.records.contains(where: { $0.path == "lib/udev/rules.d" && $0.kind == "D" }),
              source.preparation.startup.records.contains(where: { $0.path == "etc/udev/rules.d" && $0.kind == "D" }),
              source.preparation.startup.records.contains(where: { $0.path == "bin/busybox" && $0.kind == "B" }),
              source.preparation.startup.records.contains(where: { $0.path == "bin/sh" && $0.kind == "L" && $0.data == Data("busybox".utf8) }) else { throw SNESRuntimeBinding.failure() }
    }
    /// Only executable/configuration inputs consumed by the fixed startup; default rules are shadowed, never run.
    var sourceFiles: String {
        let selected = frame.records.filter { Self.consumed.contains($0.path) && ["F", "B"].contains($0.kind) }
            + source.preparation.startup.records.filter { ["bin/busybox", "etc/clover/boardtype", "etc/clover/REGION"].contains($0.path) }
        return selected.sorted { $0.path < $1.path }.map { $0.digest + "  /newroot/" + $0.path + "\n" }.joined()
    }
    private static let consumed = Set(["etc/asound.conf", "etc/clover/buildtype", "etc/clover/ui", "etc/group",
        "etc/nsswitch.conf", "etc/passwd", "etc/udev/udev.conf", "usr/bin/clover-canoe-shvc", "usr/bin/clover-mcp", "sbin/udevd", "usr/bin/udevadm"])
}
