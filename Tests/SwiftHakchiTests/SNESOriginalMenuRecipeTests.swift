import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func privateOriginalMenuMaterial() throws -> SNESOriginalMenuMaterial? {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["SWIFTHAKCHI_SNES_COMPONENTS"], let runtimePath = env["SWIFTHAKCHI_SNES_RUNTIME"],
          let support = try privateMenuSupportMaterial() else { return nil }
    let source = try SNESOriginalComponentSource(material: support)
    let components = try SNESOriginalComponentMaterial.load(source: source, directory: URL(fileURLWithPath: path))
    let runtime = try SNESRuntimeMaterial.load(directory: URL(fileURLWithPath: runtimePath), source: support.setup)
    return try SNESOriginalMenuMaterial(components: components, runtime: runtime)
}
func privateOriginalMenu(nonce: UUID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!) throws -> PreparedSNESOriginalMenu? {
    guard let material = try privateOriginalMenuMaterial() else { return nil }
    let env = ProcessInfo.processInfo.environment
    guard let hmod = env["SWIFTHAKCHI_SNES_CLOVERSHELL"], let bb = env["SWIFTHAKCHI_SNES_BUSYBOX"] else { return nil }
    let pinned = try PinnedFELInputs.load()
    return try SNESOriginalMenuRecipe.prepare(material: material,
        daemonHmod: Data(contentsOf: URL(fileURLWithPath: hmod)), busybox: Data(contentsOf: URL(fileURLWithPath: bb)),
        recovery: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage), nonce: nonce)
}
@Suite(.serialized)
struct SNESOriginalMenuRecipeTests {
    @Test func stockModulesHaveAuditedNamesVermagicAndPermissions() throws {
        guard let material = try privateOriginalMenuMaterial() else { return }
        let names = ["clvcon", "mali", "sunxi_keyboard", "sunxi_knob"]
        let permissions = [[0], [292,292,292,292,292,292,436,436], [420], [436]]
        for (i,record) in material.components.frame.records.dropLast().enumerated() {
            let module = try SNESOriginalModuleMetadata(record.data)
            #expect(module.name == names[i] && module.parameterPermissions == permissions[i])
            var wrong = record.data
            let old = Data("vermagic=3.4.113 ".utf8)
            let range = try #require(wrong.range(of: old)); wrong.replaceSubrange(range, with: Data("vermagic=3.4.112 ".utf8))
            #expect(throws: (any Error).self) { _ = try SNESOriginalModuleMetadata(wrong) }
            wrong = record.data; wrong[18] = 62
            #expect(throws: (any Error).self) { _ = try SNESOriginalModuleMetadata(wrong) }
        }
    }
    @Test func originalKernelKeyAndMembersStayExactAndOldRecipeCannotClaimIt() throws {
        guard let menu = try privateOriginalMenu() else { return }
        try menu.validateCurrent()
        let original = try LegacyBootImageBuilder.inspect(menu.material.components.source.material.setup.stock)
        let image = try LegacyBootImageBuilder.inspect(menu.image)
        #expect(image.kernel == original.kernel)
        #expect(BackupManifest.digest(image.kernel) == "512d0d6d4610721589acf7b0fed1668de3e141a0a2cb759e8885662e1652b7da")
        for entry in original.archive.entries where entry.name != "init" {
            var expected = entry; if entry.name == "." { expected.fields[4] += 1 }
            #expect(image.archive.entries.first(where: { $0.name == entry.name }) == expected)
        }
        #expect(image.archive.entries.filter { $0.name.hasSuffix(".ko") }.count == 4)
        let files = Dictionary(uniqueKeysWithValues: image.archive.entries.map { ($0.name, $0.data) })
        let checks = String(decoding: try #require(files["probe/files.sha256"]), as: UTF8.self).split(separator: "\n")
        let checkedNames = Set(checks.map { String($0.split(separator: " ").last!.dropFirst()) })
        let regularNames = Set(image.archive.entries.filter { $0.fields[1] & 0xf000 == 0x8000 && $0.name != "probe/files.sha256" }.map(\.name))
        #expect(checkedNames == regularNames)
        let common = String(decoding: try #require(files["probe/common"]), as: UTF8.self)
        let early = String(decoding: try #require(files["probe/early-init"]), as: UTF8.self)
        let run = String(decoding: try #require(files["probe/run"]), as: UTF8.self)
        #expect(early.contains("f_clover/model") && early.contains("6a03") && early.contains("Swift Hakchi SNES Original Menu Test"))
        #expect(!early.contains("f_clover/hvc") && !early.contains("6a02"))
        #expect(!early.contains("usb_role") && !common.contains("usb_role"))
        #expect(run.contains("module_params=1,195,2,194") && !run.contains("autofire") && !run.contains("home_combination"))
        #expect(!common.contains("release_menu_after_baseline") && !common.contains("/dev/clovercon1"))
        #expect(files["probe/checkpoint"] != nil && files["probe/launch"] != nil && files["probe/start"] == nil)
        #expect(!String(decoding: try #require(files["probe/report"]), as: UTF8.self).contains("> /probe/menu-host-ready"))
        let exported = try menu.checkedExport()
        let manifest = try #require(JSONSerialization.jsonObject(with: exported.manifest) as? [String: Any])
        #expect(manifest["scope"] as? String == "snes-original-menu-image")
        #expect(manifest["firmwareWritten"] as? Bool == false && manifest["firmwareRestoreEligible"] as? Bool == false)
        #expect(exported.files["original-menu.img"] == menu.image)
    }
    @Test func savedOriginalImageReconstructsAndRejectsEditedImageAndReceipt() async throws {
        guard let menu = try privateOriginalMenu() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await RecoveryBootSnapshotStore(root: root).saveSNESOriginalMenu(menu)
        let raw = try PinnedFELInputs.load(), inputs = RecoveryBootInputs(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage)
        #expect(try SNESOriginalMenuRecipe.load(directory: saved, recovery: inputs).image == menu.image)
        var bytes = menu.image; bytes[2048] ^= 1; try bytes.write(to: saved.appendingPathComponent("original-menu.img"))
        let manifestURL = saved.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        var m = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any]); m["imageSHA256"] = BackupManifest.digest(bytes)
        try JSONSerialization.data(withJSONObject: m).write(to: manifestURL)
        #expect(throws: (any Error).self) { try SNESOriginalMenuRecipe.load(directory: saved, recovery: inputs) }
        try menu.image.write(to: saved.appendingPathComponent("original-menu.img"))
        m = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any]); m["firmwareRestoreEligible"] = true
        try JSONSerialization.data(withJSONObject: m).write(to: manifestURL)
        #expect(throws: (any Error).self) { try SNESOriginalMenuRecipe.load(directory: saved, recovery: inputs) }
    }
}

extension SNESOriginalMenuRecipeTests {
    @Test func fixedLaunchRequiresTheExactCheckpointAndNeverReplays() throws {
        guard let menu = try privateOriginalMenu() else { return }
        let image = try LegacyBootImageBuilder.inspect(menu.image)
        let launch = String(decoding: try #require(image.archive.entries.first(where: { $0.name == "probe/launch" })?.data), as: UTF8.self)
        let challenge = UUID().uuidString, frame = Data("fixed checkpoint bytes\n".utf8), digest = BackupManifest.digest(frame)
        for fault in ["none", "nonce", "digest", "hash-producer", "linked-marker", "existing-marker", "source"] {
            let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let path = root.path
            try Data((menu.nonce + "\n").utf8).write(to: root.appendingPathComponent("nonce"))
            try Data("waiting-for-menu-host\n".utf8).write(to: root.appendingPathComponent("status"))
            try frame.write(to: root.appendingPathComponent("fixture-frame"))
            try Data("#!/bin/sh\n/bin/cat '\(path)/fixture-frame'\n".utf8).write(to: root.appendingPathComponent("report"))
            let guardBody = fault == "source" ? "return 9" : ":"
            try Data("require_runtime() { \(guardBody); }\n".utf8).write(to: root.appendingPathComponent("common"))
            let hash = fault == "hash-producer" ? "/usr/bin/shasum -a 256 \"$@\"; exit 9" : "exec /usr/bin/shasum -a 256 \"$@\""
            let wrapper = "#!/bin/sh\ncmd=\"$1\"; shift\ncase \"$cmd\" in sha256sum) \(hash);; *) exec \"$cmd\" \"$@\";; esac\n"
            let bb = root.appendingPathComponent("busybox"); try Data(wrapper.utf8).write(to: bb)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bb.path)
            if fault == "linked-marker" { try FileManager.default.createSymbolicLink(atPath: path + "/menu-host-ready", withDestinationPath: path + "/nonce") }
            if fault == "existing-marker" { try Data("old\n".utf8).write(to: root.appendingPathComponent("menu-host-ready")) }
            let script = launch.replacingOccurrences(of: "/probe/", with: path + "/")
            let p = Process(), output = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "launch", fault == "nonce" ? UUID().uuidString : menu.nonce, challenge, fault == "digest" ? String(repeating: "0", count: 64) : digest]
            p.standardOutput = output; p.standardError = FileHandle.nullDevice
            try p.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            #expect((p.terminationStatus == 0) == (fault == "none"))
            if fault == "none" {
                #expect(String(decoding: try Data(contentsOf: root.appendingPathComponent("menu-host-ready")), as: UTF8.self) == menu.nonce + "\n")
                #expect(String(decoding: bytes, as: UTF8.self).contains(digest))
            } else if !["linked-marker", "existing-marker"].contains(fault) {
                #expect(!FileManager.default.fileExists(atPath: path + "/menu-host-ready"))
            }
        }
    }
}


extension SNESOriginalMenuRecipeTests {
    @Test func preMenuLogFilesExistBeforeAnyFIFOWriterOrMenu() throws {
        guard let menu=try privateOriginalMenu() else{return}
        let image=try LegacyBootImageBuilder.inspect(menu.image)
        let run=String(decoding:try #require(image.archive.entries.first(where:{$0.name=="probe/run"})?.data),as:UTF8.self)
        let initialization=try #require(run.range(of:"for log in udev.log menu.log; do"))
        #expect(initialization.lowerBound < run.range(of:"mkfifo /probe/udev.pipe")!.lowerBound)
        #expect(run.contains("set -C; : > \"/probe/$log\""))
    }
}

// A missing power-key classification lets the original MCP interpret ON as OFF.
extension SNESOriginalMenuRecipeTests {
    @Test func originalKeyPropertiesRefuseMissingOrAmbiguousInputBeforeLaunch() throws {
        guard let menu = try privateOriginalMenu() else { return }
        let image = try LegacyBootImageBuilder.inspect(menu.image)
        let common = String(decoding: try #require(image.archive.entries.first(where: { $0.name == "probe/common" })?.data), as: UTF8.self)
        for fault in ["none", "missing-key", "missing-input", "wrong-key", "duplicate-key", "symlink", "hardlink", "oversized", "failed-stat", "failed-awk"] {
            let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("properties"), target = root.appendingPathComponent("target")
            var contents = "E:ID_INPUT=1\nE:ID_INPUT_KEY=1\nE:DEVNAME=/dev/input/event0\n"
            if fault == "missing-key" { contents = "E:ID_INPUT=1\n" }
            if fault == "missing-input" { contents = "E:ID_INPUT_KEY=1\n" }
            if fault == "wrong-key" { contents = "E:ID_INPUT=1\nE:ID_INPUT_KEY=0\n" }
            if fault == "duplicate-key" { contents += "E:ID_INPUT_KEY=1\n" }
            if fault == "oversized" { contents += String(repeating: "x", count: 8192) }
            try Data(contents.utf8).write(to: target)
            if fault == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target) }
            else if fault == "hardlink" { try FileManager.default.linkItem(at: target, to: file) }
            else { try Data(contents.utf8).write(to: file) }
            let badStat = fault == "failed-stat" ? "return 9" : "return 0"
            let badAwk = fault == "failed-awk" ? "return 9" : "return 0"
            let fixture = common + "\nB=host_bb\nfail() { exit 47; }\nhost_bb() { cmd=\"$1\"; shift; case \"$cmd\" in stat) shift; shift; /usr/bin/stat -f '%z:%l' \"$@\" || return; \(badStat);; awk) /usr/bin/awk \"$@\" || return; \(badAwk);; *) \"$cmd\" \"$@\";; esac; }\nrequire_key_properties \"$1\"\nprintf 'accepted\\n'\n"
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-eu", "-c", fixture, "check", file.path]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            #expect((process.terminationStatus == 0) == (fault == "none"), "case: \(fault)")
            #expect((String(decoding: result, as: UTF8.self) == "accepted\n") == (fault == "none"))
        }
    }
}
