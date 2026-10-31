import AppKit
import Testing
@testable import SwiftHakchi

struct ROMImportPanelTests {
    @Test func importWindowFitsSmallAndOffsetDisplaysInsteadOfRememberedOversize() {
        for display in [NSRect(x:0,y:25,width:1280,height:695),NSRect(x:-1440,y:40,width:1440,height:860),NSRect(x:1920,y:24,width:800,height:576)] {
            let parent=NSRect(x:display.minX-200,y:display.minY-100,width:2400,height:1600)
            let frame=ROMImportPanel.fittedFrame(parent:parent,visible:display)
            #expect(display.contains(frame))
            #expect(frame.width<=860 && frame.height<=600)
            #expect(frame.minX>=display.minX+12 && frame.maxX<=display.maxX-12)
            #expect(frame.minY>=display.minY+12 && frame.maxY<=display.maxY-12)
        }
    }
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] != "true", "Requires an interactive WindowServer")) func panelUsesConsoleSpecificGuidanceAndCapsAnOversizedFrame() {
        _=NSApplication.shared
        let panel=NSOpenPanel()
        panel.setFrame(NSRect(x:-2000,y:-2000,width:2400,height:1800),display:false)
        let visible=NSRect(x:0,y:24,width:1280,height:696)
        ROMImportPanel.fit(panel,parent:NSRect(x:100,y:60,width:1000,height:630),visible:visible)
        #expect(visible.contains(panel.frame))
        #expect(panel.maxSize.width<=visible.width && panel.maxSize.height<=visible.height)
        let message=ROMImportPolicy.pickerMessage(for:.snesUsa)
        #expect(message.contains(".smc") && !message.contains(".nes") && !message.contains("Genesis"))
        #expect(message.components(separatedBy:"\n").allSatisfy{$0.count<100})
    }
}

extension ROMImportPanelTests {
    @MainActor @Test func explicitlyRequestedNativePickerCheckStaysOnScreenAndCancelsWithoutImport() async throws {
        guard ProcessInfo.processInfo.environment["SWIFTHAKCHI_ROM_PICKER_VISUAL"]=="1" else{return}
        _=NSApplication.shared
        let host=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false;host.center();host.makeKeyAndOrderFront(nil)
        defer{host.close()}
        let panel=NSOpenPanel();panel.title="Add ROMs — SNES";panel.message=ROMImportPolicy.pickerMessage(for:.snesUsa)
        panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        panel.setFrame(NSRect(x:-2000,y:-2000,width:2400,height:1800),display:false)
        ROMImportPanel.present(panel,parent:host){_ in}
        try await Task.sleep(for:.milliseconds(700))
        defer{panel.cancel(nil)}
        let screen=try #require(host.screen)
        #expect(screen.visibleFrame.contains(panel.frame))
        #expect(panel.frame.width<=860 && panel.frame.height<=600)
        #expect(panel.sheetParent===host)
        print("ROM PICKER frame=\(panel.frame) visible=\(screen.visibleFrame)")
    }
}
