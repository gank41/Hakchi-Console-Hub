import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESFirmwareCommandsTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_FIRMWARE_COMMAND_EXPORT"] != nil))
    func exportsCommandsForExecutedFixture() async throws {
        let out=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_FIRMWARE_COMMAND_EXPORT"]))
        let m=try await SNESFirmwareFixtureCache.shared.value(),directory=SNESFirmwareCommands.directory(m.id)
        let commands=["create.sh":SNESFirmwareCommands.create(m.id),"checked.sh":SNESFirmwareCommands.checked(m),
            "verify.sh":SNESFirmwareCommands.invoke(m,writing:false),"write.sh":SNESFirmwareCommands.invoke(m,writing:true),
            "upload-writer.sh":try SSHExclusiveUpload.command(path:directory+"/writer"),"upload-input.sh":try SSHExclusiveUpload.command(path:directory+"/input")]
        for (name,value) in commands {try Data(value.utf8).write(to:out.appendingPathComponent(name),options:.withoutOverwriting)}
        let meta:[String:Any]=["id":m.id.uuidString,"directory":directory,"writerSHA":SNESBoundedWriteHelper.sha256,"writerBytes":m.writer.bytes.count,
            "inputSHA":BackupManifest.digest(m.geometry+m.preimage+m.target),"preimageSHA":BackupManifest.digest(m.preimage),"targetSHA":BackupManifest.digest(m.target),"geometrySHA":BackupManifest.digest(m.geometry)]
        try JSONSerialization.data(withJSONObject:meta,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("meta.json"),options:.withoutOverwriting)
    }
}
