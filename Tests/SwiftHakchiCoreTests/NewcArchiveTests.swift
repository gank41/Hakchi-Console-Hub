import Foundation
import Testing
@testable import SwiftHakchiCore

/// Independent fixture encoder: never uses the production archive writer.
func newcFixture(_ entries: [(String, UInt32, Data, UInt32)]) -> Data {
    var output = Data()
    for (index, entry) in (entries + [("TRAILER!!!", 0, Data(), 1)]).enumerated() {
        let (name, mode, data, links) = entry
        let fields: [UInt32] = [UInt32(index + 1), mode, 12, 34, links, 567, UInt32(data.count), 0, 0, 0, 0, UInt32(name.utf8.count + 1), 0]
        output.append(Data(("070701" + fields.map { String(format: "%08x", $0) }.joined()).utf8))
        output.append(Data(name.utf8)); output.append(0)
        while output.count % 4 != 0 { output.append(0) }
        output.append(data)
        while output.count % 4 != 0 { output.append(0) }
    }
    return output
}

struct NewcArchiveTests {
    @Test func independentArchivePreservesMetadataAndLinks() throws {
        let raw = newcFixture([(".", 0o40755, Data(), 3), ("bin", 0o40755, Data(), 2),
            ("bin/app", 0o100755, Data("hello".utf8), 1), ("bin/sh", 0o120777, Data("app".utf8), 1)])
        let archive = try NewcArchive(data: raw)
        #expect(archive.entries.count == 4)
        let item = try #require(archive.entries.first { $0.name == "bin/app" })
        #expect(item.fields[2] == 12 && item.fields[3] == 34 && item.fields[5] == 567)
        #expect(try NewcArchive(data: archive.encoded()).entries == archive.entries)
        let changed = try archive.updating(replacements: ["bin/app": Data("edited".utf8)])
        #expect(changed.entries[3] == archive.entries[3])
        #expect(changed.entries[2].data == Data("edited".utf8))
    }
    @Test func unsafePathsAndUnsupportedSemanticsAreRefused() throws {
        for name in ["/absolute", "../parent", "bin/../x", "bin//x", "bin/./x", "", "bad\u{0}name"] {
            #expect(throws: (any Error).self) { try NewcArchive(data: newcFixture([(name, 0o100644, Data(), 1)])) }
        }
        for mode: UInt32 in [0o20600, 0o10600, 0o140600] {
            #expect(throws: (any Error).self) { try NewcArchive(data: newcFixture([("special", mode, Data(), 1)])) }
        }
        #expect(throws: (any Error).self) { try NewcArchive(data: newcFixture([("hard", 0o100644, Data(), 2)])) }
        #expect(throws: (any Error).self) { try NewcArchive(data: newcFixture([("a", 0o100644, Data(), 1), ("./a", 0o100644, Data(), 1)])) }
        #expect(throws: (any Error).self) { try NewcArchive(data: newcFixture([("a", 0o120777, Data("b".utf8), 1), ("a/file", 0o100644, Data(), 1)])) }
    }
    @Test func truncatedMalformedOrTrailingRecordsAreRefused() throws {
        let good = newcFixture([("init", 0o100755, Data("abc".utf8), 1)])
        for count in [0, 6, 109, good.count - 1] {
            #expect(throws: (any Error).self) { try NewcArchive(data: Data(good.prefix(count))) }
        }
        var bad = good; bad[6] = 71
        #expect(throws: (any Error).self) { try NewcArchive(data: bad) }
        #expect(throws: (any Error).self) { try NewcArchive(data: good + Data([1])) }
        #expect(throws: (any Error).self) { try NewcArchive(data: newcFixture([("link", 0o120777, Data([0]), 1)])) }
    }
    @Test func limitsAndDirectoryAdditionsPreserveArchiveSemantics() throws {
        let root = try NewcArchive(data: newcFixture([(".", 0o40755, Data(), 2)]))
        let fields: [UInt32] = [55, 0o40755, 0, 0, 2, 0, 0, 0, 0, 0, 0, 4, 0]
        let changed = try root.updating(replacements: [:], additions: [.init(name: "new", fields: fields, data: Data())])
        #expect(changed.entries[0].fields[4] == 3)
        #expect(try NewcArchive(data: changed.encoded()) == changed)
        var childFields = fields; childFields[0] = 56; childFields[11] = 10
        let nested = try root.updating(replacements: [:], additions: [
            .init(name: "new", fields: fields, data: Data()),
            .init(name: "new/child", fields: childFields, data: Data())])
        #expect(nested.entries[0].fields[4] == 3)
        #expect(nested.entries[1].fields[4] == 3)
        #expect(throws: (any Error).self) { try root.updating(replacements: ["missing": Data()]) }
        #expect(throws: (any Error).self) { try NewcArchive(data: newcFixture([(String(repeating: "x", count: 4097), 0o100644, Data(), 1)])) }
        #expect(throws: (any Error).self) { try NewcArchive(data: newcFixture((0..<4097).map { ("x\($0)", UInt32(0o100644), Data(), UInt32(1)) })) }
        #expect(throws: (any Error).self) { try NewcArchive(data: Data(count: LZOPArchive.maximumSize + 1)) }
        var padding = newcFixture([("a", 0o100644, Data([1]), 1)]); padding[113] = 1
        #expect(throws: (any Error).self) { try NewcArchive(data: padding) }
    }
}
