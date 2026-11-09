import Foundation
import Testing
@testable import SwiftHakchi

struct AppBundleTests {
    @Test func locatesResourcesInsidePackagedApp() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let nested = resources.appendingPathComponent("SwiftHakchi_SwiftHakchi.bundle")
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        func info(_ identifier: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
                "CFBundlePackageType": "BNDL", "CFBundleName": "Fixture"], format: .xml, options: 0)
        }
        try info("example.test.app").write(to: app.appendingPathComponent("Contents/Info.plist"))
        try info("example.test.resources").write(to: nested.appendingPathComponent("Contents/Info.plist"))
        let main = try #require(Bundle(url: app))
        let bundle = try #require(Bundle.hakchiResourceBundle(in: main))
        #expect(bundle.bundleURL.standardizedFileURL.path == nested.standardizedFileURL.path)
    }
}
