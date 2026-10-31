import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESMenuLaunchHelperTests {
    @Test func bundledLauncherIsThePinnedStaticARMProgram() throws {
        let url=try #require(Bundle.module.url(forResource:"snes-menu-launch",withExtension:nil))
        let data=try Data(contentsOf:url)
        #expect(data.count==1680)
        #expect(BackupManifest.digest(data)=="ffab13eb1a1132062872764f62e5fde0125fc00df06b0ed9eb1ecd116a8ccbcd")
        #expect(try SNESMenuLaunchHelper.load()==data)
        for corrupted in [Data(data.dropLast()),data+Data([0]),Data(repeating:0,count:data.count)] {
            #expect(throws:(any Error).self) {try SNESMenuLaunchHelper.validate(corrupted)}
        }
        let elf=try ARMRuntimeELF(data:data)
        #expect(elf.type==2 && elf.interpreter==nil && elf.dependencies.isEmpty)
    }
}
