import Foundation
import SwiftHakchiCore

struct SNESRuntimeBinding: Codable, Equatable, Sendable {
    let sourceSnapshot: String, setupManifestSHA256: String, expectedHWID: String
    func validate() throws {
        guard sourceSnapshot.hasPrefix("SNES-US-Setup-"), UUID(uuidString: String(sourceSnapshot.dropFirst(14))) != nil,
              setupManifestSHA256.count == 64, Self.hex(setupManifestSHA256),
              expectedHWID.count == 32, Self.hex(expectedHWID), expectedHWID.contains(where: { $0 != "0" }) else { throw Self.failure() }
    }
    static func hex(_ s: String) -> Bool { s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func failure() -> RecoveryProbeError { .refused("The SNES runtime files or their saved console identity could not be verified. Nothing was installed.") }
}
struct SNESRuntimeFrame: Sendable {
    let loader: Data, libc: Data
    let loaderChain: String, libcChain: String
    init(_ frame: Data) throws {
        func fail() -> RecoveryProbeError { SNESRuntimeBinding.failure() }
        guard frame.count <= 4*1024*1024+4096 else { throw fail() }
        let bytes = Array(frame); var position = 0
        func line() throws -> String {
            guard position < bytes.count, let end = bytes[position..<min(position+2048, bytes.count)].firstIndex(of: 10),
                  bytes[position..<end].allSatisfy({ (32...126).contains($0) }) else { throw fail() }
            let text = String(decoding: bytes[position..<end], as: UTF8.self); position = end+1; return text
        }
        guard try line() == "SWIFTHAKCHI_SNES_RUNTIME_V1" else { throw fail() }
        var files: [(Data, String)] = []
        for role in ["loader", "libc"] {
            let parts = try line().components(separatedBy: " ")
            guard parts.count == 4, parts[0] == role, let count = Int(parts[2]), String(count) == parts[2],
                  (52...ARMRuntimeELF.maximumSize).contains(count), parts[3].count == 64, SNESRuntimeBinding.hex(parts[3]),
                  count < bytes.count - position else { throw fail() }
            try Self.validateChain(parts[1], role: role)
            let data = Data(bytes[position..<position+count]); position += count
            guard bytes[position] == 10, BackupManifest.digest(data) == parts[3] else { throw fail() }; position += 1
            let elf = try ARMRuntimeELF(data: data)
            guard elf.type == 3,
                  (role == "loader" ? elf.interpreter == nil : (elf.interpreter == nil || elf.interpreter == "/lib/ld-linux-armhf.so.3")),
                  Set(elf.dependencies) == (role == "loader" ? Set<String>() : Set(["ld-linux-armhf.so.3"])) else { throw fail() }
            files.append((data, parts[1]))
        }
        guard try line() == "END", position == bytes.count else { throw fail() }
        loader = files[0].0; loaderChain = files[0].1; libc = files[1].0; libcChain = files[1].1
    }
    static func validateChain(_ chain: String, role: String) throws {
        let parts = chain.components(separatedBy: ">")
        let first = role == "loader" ? "ld-linux-armhf.so.3" : "libc.so.6"
        let pattern = role == "loader" ? #"^ld-([0-9]+\.)+[0-9]+\.so$"# : #"^libc-([0-9]+\.)+[0-9]+\.so$"#
        guard (1...9).contains(parts.count), parts.first == first, Set(parts).count == parts.count,
              parts.allSatisfy({ $0.utf8.count <= 128 && ($0 == first || $0.range(of: pattern, options: .regularExpression) != nil) }) else { throw SNESRuntimeBinding.failure() }
    }
    var encoded: Data {
        var data = Data("SWIFTHAKCHI_SNES_RUNTIME_V1\n".utf8)
        for (role, chain, bytes) in [("loader", loaderChain, loader), ("libc", libcChain, libc)] {
            data.append(Data("\(role) \(chain) \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8)); data.append(bytes); data.append(10)
        }
        data.append(Data("END\n".utf8)); return data
    }
}

struct SNESRuntimeMaterial: Sendable {
    let binding: SNESRuntimeBinding
    let frame: SNESRuntimeFrame
    let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice
    let observation: RecoveryProbeObservation
    let directoryURL: URL?
    private let manifestSHA256: String?
    init(binding: SNESRuntimeBinding, frame: SNESRuntimeFrame, before: RecoveryProbeUSBDevice,
         after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation,
         directoryURL: URL? = nil, manifestSHA256: String? = nil) {
        self.binding = binding; self.frame = frame; self.before = before; self.after = after; self.observation = observation
        self.directoryURL = directoryURL; self.manifestSHA256 = manifestSHA256
    }
    func revalidate(source: SNESOfflineSource) throws {
        guard let directoryURL, let manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        let current = try Self.load(directory: directoryURL, source: source)
        guard current.binding == binding, current.frame.encoded == frame.encoded,
              current.manifestSHA256 == manifestSHA256 else { throw SNESRuntimeBinding.failure() }
    }
    private struct Manifest: Codable {
        let schemaVersion: Int, complete: Bool, firmwareRestoreEligible: Bool, console: String
        let binding: SNESRuntimeBinding
        let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
        let frameSHA256: String
    }
    func validate() throws {
        try binding.validate(); try SNESBackupPolicy.requireReadOnlyObservation(observation)
        guard observation.hwid == binding.expectedHWID else { throw SNESRuntimeBinding.failure() }
        _ = try before.nativeIdentity(for: .fel); _ = try after.nativeIdentity(for: .rndis)
        guard try RecoveryProbePolicy.after([after], original: before) == after else { throw SNESRuntimeBinding.failure() }
        _ = try SNESRuntimeFrame(frame.encoded)
    }
    func export(source: SNESOfflineSource) throws -> (files: [String: Data], manifest: Data) {
        try source.revalidate(); try validate()
        guard binding == source.runtimeBinding else { throw SNESRuntimeBinding.failure() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = Manifest(schemaVersion: 1, complete: true, firmwareRestoreEligible: false, console: "snes-usa",
            binding: binding, before: before, after: after, observation: observation, frameSHA256: BackupManifest.digest(frame.encoded))
        return (["runtime.frame": frame.encoded, "loader.bin": frame.loader, "libc.bin": frame.libc], try encoder.encode(manifest))
    }
    static func load(directory url: URL, source: SNESOfflineSource) throws -> Self {
        try source.revalidate()
        let directory = try RestoreDirectory(url)
        guard directory.url.lastPathComponent.hasPrefix("SNES-US-Runtime-"),
              UUID(uuidString: String(directory.url.lastPathComponent.dropFirst(16))) != nil else { throw SNESRuntimeBinding.failure() }
        let rawManifest = try directory.read("manifest.json", maximum: 65536)
        let m = try JSONDecoder().decode(Manifest.self, from: rawManifest)
        let bytes = try directory.read("runtime.frame", maximum: 4*1024*1024+4096)
        guard m.schemaVersion == 1, m.complete, !m.firmwareRestoreEligible, m.console == "snes-usa",
              m.binding == source.runtimeBinding, m.frameSHA256 == BackupManifest.digest(bytes) else { throw SNESRuntimeBinding.failure() }
        let frame = try SNESRuntimeFrame(bytes)
        guard try directory.read("loader.bin", maximum: ARMRuntimeELF.maximumSize) == frame.loader,
              try directory.read("libc.bin", maximum: ARMRuntimeELF.maximumSize) == frame.libc else { throw SNESRuntimeBinding.failure() }
        let result = Self(binding: m.binding, frame: frame, before: m.before, after: m.after, observation: m.observation,
            directoryURL: directory.url, manifestSHA256: BackupManifest.digest(rawManifest))
        try result.validate(); try directory.check(); return result
    }
}
actor SNESRuntimeCaptureService {
    private let session: RecoverySessionCoordinator
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) { session = RecoverySessionCoordinator(wait: wait) }
    func capture(binding: SNESRuntimeBinding, inputs: RecoveryBootInputs, io: any RecoveryProbeIO,
                 progress: @escaping RecoveryProgressSink = { _ in }) async throws -> SNESRuntimeMaterial {
        try binding.validate()
        let (context, frame) = try await session.run(inputs: inputs, io: io, progress: progress,
            validateObservation: { try SNESBackupPolicy.observation($0) }) { context in
            guard context.observation.hwid == binding.expectedHWID else { throw SNESRuntimeBinding.failure() }
            await progress(.verifying)
            let first = try await io.readSNESRuntime(); try Task.checkCancellation()
            let frame = try SNESRuntimeFrame(first)
            guard try await io.readSNESRuntime() == first else { throw SNESRuntimeBinding.failure() }
            try Task.checkCancellation()
            let last = try SNESBackupPolicy.observation(await io.observe())
            guard last.hwid == binding.expectedHWID, last.mounts == context.observation.mounts else { throw SNESRuntimeBinding.failure() }
            return frame
        }
        return SNESRuntimeMaterial(binding: binding, frame: frame, before: context.before, after: context.after, observation: context.observation)
    }
}
