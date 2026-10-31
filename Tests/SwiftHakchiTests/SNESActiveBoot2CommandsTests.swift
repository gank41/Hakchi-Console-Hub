import Foundation
import Testing
@testable import SwiftHakchi

struct SNESActiveBoot2CommandsTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_COMMAND_EXPORT"] != nil))
    func exportsScriptsForIndependentExecutionFixture()throws {
        let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_COMMAND_EXPORT"]),out=URL(fileURLWithPath:path)
        let id=UUID(uuidString:"22222222-2222-2222-2222-222222222222")!,challenge=UUID(uuidString:"11111111-1111-1111-1111-111111111111")!
        let scripts=["create.sh":SNESActiveBoot2Commands.create(id:id),"validate.sh":SNESActiveBoot2Commands.validation(id:id),
            "geometry.sh":SNESActiveBoot2Commands.read(id:id,kind:.geometry,challenge:challenge),"active.sh":SNESActiveBoot2Commands.read(id:id,kind:.active,challenge:challenge)]
        for (name,script) in scripts {try Data(script.utf8).write(to:out.appendingPathComponent(name),options:.withoutOverwriting)}
    }
}
