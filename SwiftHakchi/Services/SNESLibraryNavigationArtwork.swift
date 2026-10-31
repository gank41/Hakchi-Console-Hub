import AppKit
import Foundation
import SwiftHakchiCore

/// App-supplied navigation icons; no NES backup or another console's artwork is needed.
@MainActor enum SNESLibraryNavigationArtwork {
    static func standard() throws -> SNESLibraryMenu.NavigationArtwork {
        func icon(_ name: String) throws -> Data {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 204, pixelsHigh: 204, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap),
                  let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedWhite: 0.93, alpha: 1)])) else { throw SNESLibraryMenu.failure() }
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 188, height: 188), xRadius: 22, yRadius: 22).fill()
            symbol.draw(in: NSRect(x: 37, y: 37, width: 130, height: 130))
            context.flushGraphics()
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SNESLibraryMenu.failure() }
            return data
        }
        return .init(more: try icon("folder.fill"), back: try icon("arrow.uturn.backward"), custom: [:])
    }
}
