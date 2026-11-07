import Foundation
import SwiftHakchiCore

/// Durable, exact-byte helper inputs for a reviewed operation. This package
/// supplies files only; it does not authorize a console operation.
struct SNESPortableHelperPackage: Sendable {
    private struct Manifest: Codable {
        let schemaVersion: Int
        let scope: String
        let complete: Bool
        let firmwareWriteAuthorized: Bool
        let readerSHA256: String
        let writerSHA256: String
    }

    let directory: URL
    let reader: SNESBoundedReadHelper
    let writer: SNESBoundedWriteHelper
    let manifestSHA256: String

    static func export() throws -> (files: [String: Data], manifest: Data) {
        let reader = try SNESPortableHelpers.bundled(.reader)
        let writer = try SNESPortableHelpers.bundled(.writer)
        let manifest = Manifest(schemaVersion: 1, scope: "snes-portable-setup-helpers", complete: true,
                                firmwareWriteAuthorized: false, readerSHA256: reader.kind.sha256,
                                writerSHA256: writer.kind.sha256)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (["reader": reader.bytes, "writer": writer.bytes], try encoder.encode(manifest))
    }

    static func load(directory: URL) throws -> Self {
        try Task.checkCancellation()
        let dir = try RestoreDirectory(directory), prefix = "SNES-Setup-Helpers-"
        guard dir.url.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil,
              Set(try dir.names()) == Set(["manifest.json", "reader", "writer"]) else { throw SNESRuntimeBinding.failure() }
        let raw = try dir.read("manifest.json", maximum: 16_384)
        let record = try JSONDecoder().decode(Manifest.self, from: raw)
        let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? NSDictionary
        guard canonical?.isEqual(to: try JSONSerialization.jsonObject(with: raw) as? [AnyHashable: Any] ?? [:]) == true,
              record.schemaVersion == 1, record.scope == "snes-portable-setup-helpers", record.complete,
              !record.firmwareWriteAuthorized,
              SNESPortableHelpers.recognizes(kind: .reader, sha256: record.readerSHA256),
              SNESPortableHelpers.recognizes(kind: .writer, sha256: record.writerSHA256) else { throw SNESRuntimeBinding.failure() }
        let reader = try SNESBoundedReadHelper.load(dir.url.appendingPathComponent("reader"))
        let writer = try SNESBoundedWriteHelper.load(dir.url.appendingPathComponent("writer"))
        guard reader.digest == record.readerSHA256, writer.digest == record.writerSHA256 else { throw SNESRuntimeBinding.failure() }
        try dir.check(); try Task.checkCancellation()
        return .init(directory: dir.url, reader: reader, writer: writer, manifestSHA256: BackupManifest.digest(raw))
    }

    func revalidate() throws {
        let current = try Self.load(directory: directory)
        guard current.manifestSHA256 == manifestSHA256, current.reader.bytes == reader.bytes,
              current.writer.bytes == writer.bytes else { throw SNESRuntimeBinding.failure() }
    }
}

/// A saved-helper request still requires all normal per-console trial evidence.
/// Resolving it is local and does not open USB or authorize a firmware write.
struct SNESPortableFirmwareRequest: Codable, Sendable {
    let candidate: String, preflight: String, started: String, played: String, original: String, helpers: String

    static func resolve(_ raw: Data) throws -> SNESFirmwarePaths {
        let request = try JSONDecoder().decode(Self.self, from: raw)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary
        guard encoded?.isEqual(to: try JSONSerialization.jsonObject(with: raw) as? [AnyHashable: Any] ?? [:]) == true,
              [request.candidate, request.preflight, request.started, request.played, request.original, request.helpers]
                .allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
            throw SNESRuntimeBinding.failure()
        }
        let package = try SNESPortableHelperPackage.load(directory: URL(fileURLWithPath: request.helpers))
        return try SNESFirmwarePaths.withHelpers(candidate: URL(fileURLWithPath: request.candidate),
            preflight: URL(fileURLWithPath: request.preflight), started: URL(fileURLWithPath: request.started),
            played: URL(fileURLWithPath: request.played), original: URL(fileURLWithPath: request.original), helpers: package)
    }
}
