import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct SNESLibraryMaterialGuardTests {
    @Test(arguments: ["valid", "rom-replaced", "metadata-edited", "artifact-replaced", "extra-artifact"])
    func reviewCannotSurviveChangedSourcesAcrossAnAwait(_ fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root), menu = try fixture.menu(review, originals)
        let material = try SNESLibraryMaterial.freeze(menu: menu, in: root), seal = try SNESLibraryMaterialGuard.prepare(material)
        try seal.require()
        switch fault {
        case "rom-replaced":
            let source = try #require(menu.sources.first { $0.name.hasSuffix(".sfc") }), path = URL(fileURLWithPath: source.directory).appendingPathComponent(source.name)
            let data = try Data(contentsOf: path); try FileManager.default.removeItem(at: path); try data.write(to: path)
        case "metadata-edited":
            let source = try #require(menu.sources.first { $0.name.hasSuffix(".desktop") }), path = URL(fileURLWithPath: source.directory).appendingPathComponent(source.name)
            var data = try Data(contentsOf: path); data.append(10); try data.write(to: path)
        case "artifact-replaced":
            let path = material.directory.appendingPathComponent("menu.json"), data = try Data(contentsOf: path)
            try FileManager.default.removeItem(at: path); try data.write(to: path)
        case "extra-artifact": try Data([0]).write(to: material.directory.appendingPathComponent("unexpected"))
        default:
            try Data([1]).write(to: root.appendingPathComponent("unrelated-file"))
        }
        if fault == "valid" { try seal.require(); #expect(seal.material.reviewSHA256 == material.reviewSHA256) }
        else { #expect(throws: (any Error).self) { try seal.require() } }
    }
}
