import Foundation

extension Bundle {
    static func hakchiResourceBundle(in main: Bundle) -> Bundle? {
        guard let resourceURL = main.resourceURL else { return nil }
        return Bundle(url: resourceURL.appendingPathComponent("SwiftHakchi_SwiftHakchi.bundle"))
    }
    /// Resource bundle accessor that works inside a .app bundle.
    ///
    /// SPM's auto-generated `Bundle.module` looks at `Bundle.main.bundleURL`
    /// (the .app root), but codesign requires all content inside `Contents/`.
    /// This accessor checks `Bundle.main.resourceURL` (`Contents/Resources/`)
    /// first, then falls back to the SPM-generated `Bundle.module`.
    static let appBundle: Bundle = {
        if let bundle = hakchiResourceBundle(in: .main) { return bundle }

        #if SWIFTHAKCHI_DISTRIBUTION
        // A public bundle must never depend on a path from the build machine.
        fatalError("The app's resource bundle is missing. Reinstall the app.")
        #else
        // Fallback to SPM's auto-generated accessor (works for `swift run`)
        return Bundle.module
        #endif
    }()
}
