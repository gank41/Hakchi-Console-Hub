import Foundation
import Testing
@testable import SwiftHakchi

struct SNESFirmwareJournalPolicyTests {
    @Test func backupFolderCannotReplaceStableFirmwareJournalRoot()throws {
        let root=try SNESFirmwareJournalPolicy.root(),id=UUID().uuidString
        try SNESFirmwareJournalPolicy.requireOperation(root.appendingPathComponent("SNESFirmware-"+id))
        for wrong in [URL(fileURLWithPath:"/private/tmp/Backups").appendingPathComponent("SNESFirmware-"+id),root.appendingPathComponent("Other-"+id),root.appendingPathComponent("SNESFirmware-hello"),root] {
            #expect(throws:(any Error).self){try SNESFirmwareJournalPolicy.requireOperation(wrong)}
        }
    }
}
