import AppKit

/// Size the native ROM picker from its actual parent display, including secondary
/// displays with negative coordinates. Remembered Finder panel sizes cannot push
/// the initial picker beyond the visible screen.
enum ROMImportPanel {
    static func fittedFrame(parent:NSRect?,visible:NSRect)->NSRect {
        let bounds=visible.insetBy(dx:12,dy:12)
        let anchor=parent ?? bounds
        let size=NSSize(width:min(bounds.width,min(860,max(640,anchor.width*0.9))),
                        height:min(bounds.height,min(600,max(420,anchor.height*0.9))))
        return NSRect(x:min(max(anchor.midX-size.width/2,bounds.minX),bounds.maxX-size.width),
                      y:min(max(anchor.midY-size.height/2,bounds.minY),bounds.maxY-size.height),
                      width:size.width,height:size.height)
    }
    @MainActor static func fit(_ panel:NSOpenPanel,parent:NSRect?,visible:NSRect) {
        let bounds=visible.insetBy(dx:12,dy:12)
        panel.minSize=NSSize(width:min(560,bounds.width),height:min(360,bounds.height))
        panel.maxSize=bounds.size
        panel.setFrame(fittedFrame(parent:parent,visible:visible),display:false)
    }
    @MainActor static func present(_ panel:NSOpenPanel,parent:NSWindow?=nil,completion:@escaping @MainActor(NSApplication.ModalResponse)->Void) {
        let host=parent ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let visible=(host?.screen ?? NSScreen.main)?.visibleFrame {
            fit(panel,parent:host?.frame,visible:visible)
        }
        if let host,host !== panel {
            panel.beginSheetModal(for:host){response in Task { @MainActor in completion(response) }}
        } else {
            panel.begin{response in Task { @MainActor in completion(response) }}
        }
    }
}
