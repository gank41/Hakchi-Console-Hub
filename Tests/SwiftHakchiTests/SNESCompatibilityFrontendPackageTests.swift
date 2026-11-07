import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESCompatibilityFrontendPackageTests {
    @Test func bundledFrontendIsTheReviewedTargetBuild() throws {
        let package = try SNESCompatibilityFrontendPackage.loadBundled()
        #expect(package.frontend.count == 2_657_408)
        #expect(BackupManifest.digest(package.frontend) == "2aa763b0ccd4a783bcb88bdd8e012e38cd8b60c2d5ece7f4db847a71d941f972")
        #expect(throws: (any Error).self) { try ARMRuntimeELF(data: package.frontend) }
        var changed = package.frontend
        changed[100] ^= 1
        #expect(throws: (any Error).self) { try ARMRuntimeELF.reviewedCompatibilityFrontend(data: changed) }
        #expect(package.frontend.range(of: Data("/Users/".utf8)) == nil)
        #expect(package.frontend.range(of: Data("/private/tmp/".utf8)) == nil)
        #expect(package.inspection.type == 2)
        #expect(package.inspection.interpreter == "/lib/ld-linux-armhf.so.3")
        #expect(package.patch.count == 3945)
        for bad in [Data(), Data(package.frontend.dropLast()), package.frontend + Data([0])] {
            #expect(throws: (any Error).self) { try SNESCompatibilityFrontendPackage(frontend: bad, patch: package.patch, license: package.license) }
        }
        #expect(throws: (any Error).self) { try SNESCompatibilityFrontendPackage(frontend: package.frontend, patch: package.patch + Data([0]), license: package.license) }
        #expect(throws: (any Error).self) { try SNESCompatibilityFrontendPackage(frontend: package.frontend, patch: package.patch, license: Data()) }
    }
}
