import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESRAMLaunchObservationTests {
    @Test func ramReaderUsesTemporaryBusyboxAndHashesItsInput() throws {
        let script = "printf 'hello'"
        let envelope = try SNESRAMLaunchObservation.envelope(script)
        #expect(envelope.command.contains("B=/probe/busybox"))
        #expect(!envelope.command.contains("/mnt/swifthakchi"))
        #expect(envelope.input == Data(script.utf8))
        #expect(envelope.command.contains(BackupManifest.digest(envelope.input)))
        #expect(throws: (any Error).self) { try SNESRAMLaunchObservation.envelope("") }
    }
    @Test func acceptsOnlyBoundedTransitionDetails() throws {
        let input = "HC-MENU-OBS-V1\nPARENT 41\nARG wait 11 eventfd\nARG start 13 eventfd\nARG finish - invalid\nEND\n"
        let parsed = try SNESRAMLaunchObservation.parse(Data(input.utf8))
        #expect(parsed.parent == 41)
        #expect(parsed.transitions.count == 3)
        #expect(parsed.transitions[0].number == 11)
        #expect(parsed.transitions[2].number == nil)
        for bad in ["PARENT /private/path", "ARG other 11 eventfd", "ARG wait 999 eventfd", "ARG wait 4 /secret", "ARG wait - eventfd"] {
            let text = "HC-MENU-OBS-V1\nPARENT 41\n" + bad + "\nEND\n"
            #expect(throws: (any Error).self) { try SNESRAMLaunchObservation.parse(Data(text.utf8)) }
        }
    }
}
