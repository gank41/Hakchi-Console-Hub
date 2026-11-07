import Foundation
import Testing
@testable import SwiftHakchi

struct SNESRAMLifecycleObservationTests {
    @Test func acceptsOnlyBoundedKnownEvents() throws {
        let raw=Data("OWNER_START\nPOWER_READY\nWAIT_BEGIN\nWAIT_DONE\nGAME_STARTED\nSIGNAL_RECEIVED\nTRANSITION_BEGIN\n".utf8)
        let values=try SNESRAMLifecycleObservation.parse(raw)
        #expect(values.count==7 && values.last=="TRANSITION_BEGIN")
        for bad in ["", "OWNER_START", "OWNER_START\n/private/path\n", String(repeating:"OWNER_START\n",count:65)] {
            #expect(throws:(any Error).self) {try SNESRAMLifecycleObservation.parse(Data(bad.utf8))}
        }
    }
    @Test func acceptsRecordedEarlyFailures() throws {
        for event in ["ARGUMENTS_FAILED", "TERM_SETUP_FAILED"] {
            let values = try SNESRAMLifecycleObservation.parse(Data("OWNER_START\n\(event)\n".utf8))
            #expect(values == ["OWNER_START", event])
        }
    }
}
