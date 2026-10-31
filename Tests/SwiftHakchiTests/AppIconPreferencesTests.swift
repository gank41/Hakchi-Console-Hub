import Foundation
import Testing
import AppKit
@testable import SwiftHakchi

@MainActor struct AppIconPreferencesTests {
    @Test func existingSettingsUsePOWWithoutLosingTheirWorkspace() throws {
        let json = Data(#"{"workspacePath":"/test/library"}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(config.appIconID == "pow-block")
        #expect(config.workspacePath == "/test/library")
    }
    @Test func chosenAlternatePersistsAcrossLaunches() throws {
        let config = AppConfig(); config.appIconID = "nes"
        let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.appIconID == "nes")
    }
    @Test func unknownOrPathPreferencesUseTheDefaultInsteadOfOpeningAnArbitraryImage() throws {
        let json = Data(#"{"appIconID":"../../outside.icns"}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(config.appIconID == "pow-block")
    }
    @Test func malformedCosmeticPreferenceDoesNotDiscardStorageSettings() throws {
        let data = Data(#"{"workspacePath":"/test/kept","backupDirectoryPath":"/test/backups","appIconID":42}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(config.appIconID == "pow-block" && config.workspacePath == "/test/kept")
        #expect(config.backupDirectoryPath == "/test/backups")
    }
    @Test func everySuppliedIconIsBundledAndReadable() throws {
        #expect(AppIconCatalog.choices.count == 38)
        #expect(Set(AppIconCatalog.choices.map(\.id)).count == 38)
        for choice in AppIconCatalog.choices {
            let url = try #require(AppIconCatalog.imageURL(for: choice.id))
            let image = try #require(NSImage(contentsOf: url))
            #expect(image.isValid && image.size.width >= 256 && image.size.height >= 256)
        }
    }
    @Test(arguments: ["path", "duplicate", "no-default"])
    func damagedCatalogCannotIntroducePathsOrAmbiguousChoices(_ fault: String) throws {
        var rows = [["id": "pow-block", "title": "POW Block"]]
        switch fault {
        case "path": rows.append(["id": "../outside", "title": "Outside"])
        case "duplicate": rows.append(rows[0])
        default: rows = [["id": "nes", "title": "NES"]]
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        #expect(throws: (any Error).self) { try AppIconCatalog.decode(data) }
    }

}
