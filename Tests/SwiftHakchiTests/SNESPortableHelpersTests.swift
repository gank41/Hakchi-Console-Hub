import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESPortableHelpersTests {
    @Test func priorPortableIdentitiesRemainRecognizedIndependentlyOfCurrentSelection() {
        let v1 = SNESPortableHelpers.Version.v1
        #expect(SNESPortableHelpers.recognizes(kind: .reader, byteCount: 2_560, sha256: v1.reader.sha256))
        #expect(SNESPortableHelpers.recognizes(kind: .writer, byteCount: 31_512, sha256: v1.writer.sha256))
        #expect(!SNESPortableHelpers.recognizes(kind: .reader, byteCount: 2_561, sha256: v1.reader.sha256))
        #expect(!SNESPortableHelpers.recognizes(kind: .writer, byteCount: 31_512, sha256: v1.reader.sha256))
    }
    @Test(arguments: SNESPortableHelpers.Kind.allCases)
    func bundledHelperHasExactVerifiedBytesAndNoPrivateBuildPaths(_ kind: SNESPortableHelpers.Kind) throws {
        let helper = try SNESPortableHelpers.bundled(kind)
        #expect(helper.kind == kind)
        #expect(helper.bytes.count == kind.byteCount)
        #expect(BackupManifest.digest(helper.bytes) == kind.sha256)
        #expect(helper.bytes.range(of: Data("/Users/".utf8)) == nil)
        #expect(helper.bytes.range(of: Data("/Development/NES".utf8)) == nil)
        #expect(!helper.firmwareWriteAuthorized)
    }

    @Test(arguments: SNESPortableHelpers.Kind.allCases)
    func changedOrWrongKindBytesAreRejected(_ kind: SNESPortableHelpers.Kind) throws {
        let helper = try SNESPortableHelpers.bundled(kind)
        var changed = helper.bytes
        changed[changed.count - 1] ^= 1
        #expect(throws: (any Error).self) { try SNESPortableHelpers.validate(changed, as: kind) }
        #expect(throws: (any Error).self) { try SNESPortableHelpers.validate(Data(helper.bytes.dropLast()), as: kind) }
        let other: SNESPortableHelpers.Kind = kind == .reader ? .writer : .reader
        #expect(throws: (any Error).self) { try SNESPortableHelpers.validate(helper.bytes, as: other) }
    }

    @Test func reviewedReaderCanBeUsedByTheExistingPhysicalReadPath() throws {
        let portable = try SNESPortableHelpers.bundled(.reader)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reader")
        try portable.bytes.write(to: file)
        let reader = try SNESBoundedReadHelper.load(file)
        #expect(reader.digest == SNESPortableHelpers.Kind.reader.sha256)
        let command = SNESActiveBoot2Commands.validation(id: UUID(), helper: reader)
        #expect(command.contains(reader.digest))
        #expect(command.contains(String(portable.bytes.count)))
    }

    @Test func reviewedWriterCanBeUsedOnlyWithItsExactIdentity() throws {
        let portable = try SNESPortableHelpers.bundled(.writer)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("writer")
        try portable.bytes.write(to: file)
        let writer = try SNESBoundedWriteHelper.load(file)
        #expect(writer.digest == SNESPortableHelpers.Kind.writer.sha256)
        try writer.revalidate()
        var changed = portable.bytes; changed[changed.count - 1] ^= 1
        try changed.write(to: file)
        #expect(throws: (any Error).self) { try writer.revalidate() }
    }

    @Test func bundledHelpersCanBeLoadedByTheExistingTransactionTypes() throws {
        let reader = try SNESPortableHelpers.bundledReader()
        let writer = try SNESPortableHelpers.bundledWriter()
        #expect(reader.digest == SNESPortableHelpers.Kind.reader.sha256)
        #expect(writer.digest == SNESPortableHelpers.Kind.writer.sha256)
        try reader.revalidate()
        try writer.revalidate()
    }
}
