import Testing
@testable import SwiftHakchi

struct GameDetailAccessTests {
    @Test func modernRemoteDownloadRemainsAvailableWhenEditingIsDisabled() {
        for source in [GameSource.stock, .console] {
            let access = GameDetailAccess(source: source, hasSSH: true, isLegacyInspection: false)
            #expect(!access.canEditMetadata)
            #expect(access.canDownloadROM)
        }
    }
    @Test func legacyInspectionCannotEnableEditingOrDownload() {
        let access = GameDetailAccess(source: .console, hasSSH: false, isLegacyInspection: true)
        #expect(!access.canEditMetadata && !access.canDownloadROM)
    }
    @Test func disconnectedLocalCopyCanBeEditedWithoutDownload() {
        let access = GameDetailAccess(source: .local, hasSSH: false, isLegacyInspection: false)
        #expect(access.canEditMetadata && !access.canDownloadROM)
    }
}
