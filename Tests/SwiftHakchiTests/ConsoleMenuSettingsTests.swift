import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor
struct ConsoleMenuSettingsTests {
    @Test func oldAndInvalidConfigurationKeepsOtherSettingsAndUsesDefaultLimit() throws {
        for json in [#"{"lastDeviceId":"PRESERVE"}"#, #"{"consoleMenuLimit":999,"lastDeviceId":"PRESERVE"}"#,
                     #"{"consoleMenuLimit":"invalid","lastDeviceId":"PRESERVE"}"#] {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
            #expect(config.consoleMenuLimit.rawValue == 30)
            #expect(config.lastDeviceId == "PRESERVE")
        }
    }
    @Test func chosenLimitSurvivesConfigurationRoundTrip() throws {
        let config = AppConfig()
        config.consoleMenuLimit = .twentyFive
        config.libraryOrder = .dateModified
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(reloaded.consoleMenuLimit == .twentyFive)
        #expect(reloaded.libraryOrder == .dateModified)
    }
}
