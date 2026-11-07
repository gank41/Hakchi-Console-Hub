import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESFirmwareSourceSealTests {
    @Test func pinsDigestToTheSealedDirectoryAndHelperIdentities() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("source"), helperDirectory = root.appendingPathComponent("helpers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: false)
        let manifest = directory.appendingPathComponent("manifest.json"), helper = helperDirectory.appendingPathComponent("reader")
        let bytes = Data([1, 2, 3]), tool = Data([4, 5]); try bytes.write(to: manifest); try tool.write(to: helper)
        let seal = try SNESFirmwareSourceSeal.capture(directories: [directory], files: [helper])
        try seal.requireFileDigest(manifest, sha256: BackupManifest.digest(bytes), maximum: 65536)
        try seal.requireFileDigest(helper, sha256: BackupManifest.digest(tool), maximum: 65536)
        #expect(throws: (any Error).self) { try seal.requireFileDigest(manifest, sha256: String(repeating: "0", count: 64), maximum: 65536) }
        try FileManager.default.removeItem(at: manifest); try bytes.write(to: manifest)
        #expect(throws: (any Error).self) { try seal.requireFileDigest(manifest, sha256: BackupManifest.digest(bytes), maximum: 65536) }
    }
    @Test(arguments:["none","content","mtime-restored","replace","link","extra","directory-link","parent-extra"])
    func tracksSourceIdentityAndChangesWithoutHashingWholeBackups(_ fault:String)throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let directory=root.appendingPathComponent("source"),helperDir=root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        try FileManager.default.createDirectory(at:helperDir,withIntermediateDirectories:false)
        let file=directory.appendingPathComponent("data"),helper=helperDir.appendingPathComponent("reader")
        try Data([1,2,3]).write(to:file);try Data([4,5]).write(to:helper)
        let date=try FileManager.default.attributesOfItem(atPath:file.path)[.modificationDate]
        let seal=try SNESFirmwareSourceSeal.capture(directories:[directory],files:[helper])
        switch fault {
        case "content","mtime-restored":
            try Data([3,2,1]).write(to:file)
            if fault=="mtime-restored",let date {try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:file.path)}
        case "replace":try FileManager.default.removeItem(at:file);try Data([1,2,3]).write(to:file)
        case "link":try FileManager.default.linkItem(at:file,to:root.appendingPathComponent("hardlink"))
        case "extra":try Data([0]).write(to:directory.appendingPathComponent("extra"))
        case "directory-link":
            let moved=root.appendingPathComponent("moved");try FileManager.default.moveItem(at:directory,to:moved)
            try FileManager.default.createSymbolicLink(at:directory,withDestinationURL:moved)
        case "parent-extra":try Data([0]).write(to:helperDir.appendingPathComponent("unrelated"))
        default:break
        }
        if ["none","parent-extra"].contains(fault) {try seal.validate()}
        else {#expect(throws:(any Error).self){try seal.validate()}}
    }
}
