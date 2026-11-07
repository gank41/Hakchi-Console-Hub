import Foundation
import Testing
@testable import SwiftHakchi

struct SNESCompatibilityProbePackageTests {
    @Test func bundledProbeHasPinnedExecutableAndSource() throws {
        let package = try SNESCompatibilityProbePackage.loadBundled()
        #expect(package.executable.count == 5_428)
        #expect(package.inspection.type == 2)
        #expect(package.inspection.interpreter == "/lib/ld-linux-armhf.so.3")
        #expect(!package.source.isEmpty)
        var changed = package.executable
        changed[changed.startIndex] ^= 1
        #expect(throws: (any Error).self) {
            try SNESCompatibilityProbePackage(executable: changed, source: package.source)
        }
        var changedSource = package.source
        changedSource.append(0)
        #expect(throws: (any Error).self) {
            try SNESCompatibilityProbePackage(executable: package.executable, source: changedSource)
        }
    }
}
