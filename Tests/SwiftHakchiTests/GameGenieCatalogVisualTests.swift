import AppKit
import SwiftUI
import Testing
@testable import SwiftHakchi
struct GameGenieCatalogVisualTests {
    @MainActor @Test func explicitCatalogVisualCheck() async throws {
        guard let path=ProcessInfo.processInfo.environment["SWIFTHAKCHI_CATALOG_VISUAL_OUTPUT"] else{return}
        _=NSApplication.shared
        let game=ProcessInfo.processInfo.environment["SWIFTHAKCHI_CATALOG_VISUAL_GAME"] ?? "Contra"
        let system=GameGenieSystem(rawValue:ProcessInfo.processInfo.environment["SWIFTHAKCHI_CATALOG_VISUAL_SYSTEM"] ?? "nes") ?? .nes
        let targeted=ProcessInfo.processInfo.environment["SWIFTHAKCHI_CATALOG_VISUAL_TARGET"]=="1"
        let choose:((GameGenieEffect)->Void)?=targeted ? {_ in}:nil
        let view=NSHostingView(rootView:GameGenieCatalogView(gameName:game,system:system,onChoose:choose).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1020,height:740),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.appearance=NSAppearance(named:.aqua)
        window.contentView=view
        window.makeKeyAndOrderFront(nil)
        defer{window.close()}
        try await Task.sleep(for:.milliseconds(700))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let rep=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:rep)
        let data=try #require(rep.representation(using:.png,properties:[:]))
        try data.write(to:URL(fileURLWithPath:path))
    }
}
