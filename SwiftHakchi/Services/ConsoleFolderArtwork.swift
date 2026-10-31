import AppKit
import Foundation
import ImageIO
import SwiftHakchiCore

/// Resolves folder art only from a verified factory backup or source captured in the review.
enum ConsoleFolderArtwork {
    /// Uses the same tile/scaling path as staging. Classic icons come from the verified NES backup.
    static func previewData(for link: ConsoleMenuGraph.Link, style: ConsoleStructure.FolderArt,
                            artworkDirectory: URL?) throws -> Data {
        guard link.role != .back else {
            throw SyncPlanError.invalidInput("Back uses the Classic console icon.")
        }
        switch style {
        case .classic:
            throw SyncPlanError.invalidInput("Classic folder art is read from the verified console backup.")
        case .letterTiles:
            let label = link.title.count <= 2 ? link.title : String(link.title.prefix(6))
            return try tile(label, size: 204)
        case .custom:
            guard let key = link.artKey, let artworkDirectory else {
                throw SyncPlanError.invalidInput("This folder uses the Classic console icon.")
            }
            let source = try LegacySyncPlan.SourceFile.capture(artworkDirectory.appendingPathComponent(key))
            return try images(for: link, style: .custom, classicLarge: Data(), classicSmall: Data(),
                              sources: [key: source]).large
        }
    }

    static func images(for link: ConsoleMenuGraph.Link, style: ConsoleStructure.FolderArt,
                       classicLarge: Data, classicSmall: Data,
                       sources: [String: LegacySyncPlan.SourceFile]) throws -> (large: Data, small: Data) {
        if link.role == .back || style == .classic { return (classicLarge, classicSmall) }
        if style == .custom {
            guard let key = link.artKey else { return (classicLarge, classicSmall) }
            guard let source = sources[key] else {
                throw SyncPlanError.invalidInput("A reviewed folder image is missing.")
            }
            try source.verify()
            let png = try GameArtworkStore.png(from: Data(contentsOf: source.url))
            return (try scaledPNG(png, size: 204), try scaledPNG(png, size: 40))
        }
        let label = link.title.count <= 2 ? link.title : String(link.title.prefix(6))
        return (try tile(label, size: 204), try tile(label, size: 40))
    }

    private static func tile(_ text: String, size: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw SyncPlanError.invalidInput("Folder artwork could not be generated.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        NSColor(calibratedRed: 0.88, green: 0.68, blue: 0.28, alpha: 1).setStroke()
        let inset = CGFloat(size) * 0.08
        let border = NSBezierPath(roundedRect: NSRect(x: inset, y: inset,
            width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset),
            xRadius: CGFloat(size) * 0.08, yRadius: CGFloat(size) * 0.08)
        border.lineWidth = max(1, CGFloat(size) * 0.025)
        border.stroke()
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(size) * (text.count > 2 ? 0.19 : 0.43), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let string = NSString(string: text)
        let measured = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: (CGFloat(size) - measured.width) / 2,
                                y: (CGFloat(size) - measured.height) / 2), withAttributes: attributes)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SyncPlanError.invalidInput("Folder artwork could not be encoded.")
        }
        return data
    }

    private static func scaledPNG(_ data: Data, size: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SyncPlanError.invalidInput("Folder artwork could not be resized.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { throw SyncPlanError.invalidInput("Folder artwork is invalid.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw SyncPlanError.invalidInput("Folder artwork could not be encoded.")
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SyncPlanError.invalidInput("Folder artwork could not be encoded.")
        }
        return output as Data
    }
}
