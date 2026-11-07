import Foundation
import Testing
@testable import SwiftHakchi

struct SNESCompatibilityInstalledSupportCommandTests {
    @Test func validatesHelperAndExactReadOnlyReceipt() throws {
        let hash = String(repeating: "a", count: 64)
        let command = try SNESCompatibilityInstalledSupportCommand.prepare(helperSHA256: hash)
        #expect(command.command.contains("sha256sum"))
        #expect(command.command.contains("--check-compatibility-support"))
        #expect(command.command.contains(hash))
        #expect(try command.validateReceipt(Data("COMPATIBILITY SUPPORT MATCHES\nConsole launch is not enabled.\n".utf8)))
        #expect(throws: (any Error).self) { try command.validateReceipt(Data("COMPATIBILITY SUPPORT MATCHES\n".utf8)) }
        #expect(throws: (any Error).self) { try command.validateReceipt(Data("COMPATIBILITY SUPPORT MATCHES\nConsole launch is not enabled.\nextra".utf8)) }
        #expect(throws: (any Error).self) { try SNESCompatibilityInstalledSupportCommand.prepare(helperSHA256: "bad; touch x") }
        if let output = ProcessInfo.processInfo.environment["HC_INSTALLED_SUPPORT_COMMAND"],
           let digest = ProcessInfo.processInfo.environment["HC_INSTALLED_SUPPORT_HELPER_SHA"] {
            let fixture = try SNESCompatibilityInstalledSupportCommand.prepare(helperSHA256: digest)
            try Data(fixture.command.utf8).write(to: URL(fileURLWithPath: output))
        }
    }
}
