import Foundation
import Testing
@testable import SwiftHakchi

struct SNESTemporaryMenuDiagnosticTests {
    @Test func fixedReportCommandCannotAcceptCallerShellText() {
        let request = LegacyReadRequest.snesTemporaryMenuReport(challenge: menuChallenge)
        #expect(request.command == "exec /probe/busybox sh /probe/report 44444444-4444-4444-4444-444444444444")
        #expect(request.maximumOutputBytes == 65536 && !request.isBinary)
        #expect(LegacyReadRequest.snesTemporaryMenuDiagnostics.maximumOutputBytes == 65536)
    }
    @Test func strictModesRejectIncompleteOrRelativeInputs() throws {
        #expect(try SNESTemporaryMenuDiagnosticOptions.parseIfPresent(["--test-snes-menu", "/saved/image"]) == .test("/saved/image"))
        #expect(try SNESTemporaryMenuDiagnosticOptions.parseIfPresent(["--check-snes-menu", "/image", "/started"]) == .check("/image", "/started"))
        #expect(try SNESTemporaryMenuDiagnosticOptions.parseIfPresent(["--inspect"]) == nil)
        for args in [["--test-snes-menu"], ["--test-snes-menu", "relative"], ["--check-snes-menu", "/image"], ["--test-snes-menu", "/image", "/extra"]] {
            #expect(throws: (any Error).self) { try SNESTemporaryMenuDiagnosticOptions.parseIfPresent(args) }
        }
    }
    @Test func invalidSavedImageStopsBeforeHostOrUSBFactory() async {
        await #expect(throws: (any Error).self) {
            try await SNESTemporaryMenuDiagnostic.runIfPresent(["--test-snes-menu", "/not-a-real-menu"],
                checkHost: { Issue.record("Invalid image reached host gate") },
                makeIO: { _ in Issue.record("Invalid image reached USB construction"); return TemporaryMenuFakeIO() })
        }
    }
}

struct SNESTemporaryMenuPartialReplyTests {
    @Test(arguments: [true, false])
    func incompleteRepliesAreKeptOnlyForTheOptInDiagnostic(retain: Bool) async throws {
        let usb = LegacyFakeUSB(.missingEOF)
        let client = LegacyInspectionClient(transport: usb, maximumOutputBytes: 65536, retainIncompleteOutput: retain)
        try await client.connect()
        await #expect(throws: (any Error).self) { try await client.execute(.snesTemporaryMenuReport(challenge: menuChallenge), timeoutMilliseconds: 100) }
        let partial = await client.incompleteOutput()
        #expect(partial.stdout == (retain ? Data([0,1,255,0,2]) : Data()))
        #expect(partial.stderr == (retain ? Data("diagnostic".utf8) : Data()))
    }
}
