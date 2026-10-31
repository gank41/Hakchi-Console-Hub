import Foundation
import Testing
@testable import SwiftHakchi

func privateMenuSupportMaterial() throws -> SNESMenuSupportMaterial? {
    let env = ProcessInfo.processInfo.environment
    guard let setup = env["SWIFTHAKCHI_SNES_SETUP"], let prep = env["SWIFTHAKCHI_SNES_PREPARATION"],
          let support = env["SWIFTHAKCHI_SNES_MENU_SUPPORT"] else { return nil }
    let source = try SNESMenuSupportSource.load(setup: SNESOfflineSource.load(snapshot: URL(fileURLWithPath: setup)), preparation: URL(fileURLWithPath: prep))
    return try SNESMenuSupportMaterial.load(source: source, directory: URL(fileURLWithPath: support))
}
@Suite(.serialized)
struct SNESMenuSupportMaterialTests {
    @Test func actualCapturedSourceProducesOnlyTheAuditedUSRecipe() throws {
        guard let material = try privateMenuSupportMaterial() else { return }
        try material.requireRecipeInputs()
        #expect(material.frame.records.first { $0.path == "etc/clover/ui" }?.data == Data("snes-usa".utf8))
        #expect(material.sourceFiles.contains("dff55752d9c101ff175a9d6b9c31022e1dd6304392a190cdd6e3be36f013946c  /newroot/usr/bin/clover-mcp\n"))
        #expect(!material.sourceFiles.contains("lib/udev/rules.d/80-drivers.rules"))
    }
    @Test(arguments: ["frame", "manifest"])
    func changedSupportCannotAuthorizeABuild(fault: String) throws {
        guard let original = try privateMenuSupportMaterial() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent(original.directoryURL.lastPathComponent)
        try FileManager.default.copyItem(at: original.directoryURL, to: copy)
        let material = try SNESMenuSupportMaterial.load(source: original.source, directory: copy)
        let name = fault == "frame" ? "support.frame" : "manifest.json"
        try Data([1]).write(to: copy.appendingPathComponent(name))
        #expect(throws: (any Error).self) { try material.revalidate() }
    }
}
