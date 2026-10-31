import Foundation
import Testing
@testable import SwiftHakchi

struct SNESLibraryRoutingTests {
    @Test(arguments: ["stock", "legacy", "library", "builtin", "invalid-new", "linked-new"])
    func newSelectionTakesPrecedenceWithoutExecutingAnInvalidOrOldMenu(_ mode: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime"), old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        for directory in [runtime, old, new] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: runtime.appendingPathComponent(name)) }
        let legacy = root.appendingPathComponent("legacy-called")
        try write("menu-selector", "#!/bin/sh\nprintf yes > '\(legacy.path)'\nprintf '/legacy/games\\n'\n")
        try write("library-selector", mode == "invalid-new" || mode == "linked-new" ? "#!/bin/sh\nexit 23\n" : "#!/bin/sh\nprintf '%s\\n' '\(mode == "builtin" ? "/usr/share/games" : "/reviewed/pages/000")'\n")
        let bb = runtime.appendingPathComponent("busybox")
        try write("busybox", """
        #!/bin/sh
        case "$1" in
          stat) case "$3" in '%h') exec /usr/bin/stat -f '%l' "$4";; '%u') echo 0;; '%s') exec /usr/bin/stat -f '%z' "$4";; *) exit 97;; esac;;
          *) exec "$@";;
        esac
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bb.path)
        if mode != "stock" { try Data("old\n".utf8).write(to: old.appendingPathComponent("active-menu")) }
        if ["library", "builtin", "invalid-new"].contains(mode) {
            let selection = mode == "builtin" ? "SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nBUILTIN\n" : mode == "invalid-new" ? "new\n" : "SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n" + UUID().uuidString + "\n" + String(repeating: "a", count: 64) + "\n"
            try Data(selection.utf8).write(to: new.appendingPathComponent("active-menu"))
        }
        if mode == "linked-new" { try FileManager.default.createSymbolicLink(at: new.appendingPathComponent("active-menu"), withDestinationURL: root.appendingPathComponent("absent")) }
        let source = root.appendingPathComponent("route.sh")
        let script = SNESLibraryStartupScripts.route.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: SNESLibraryMenu.namespace, with: new.path).replacingOccurrences(of: SNESOneGameMenu.namespace, with: old.path)
        try Data(script.utf8).write(to: source)
        let process = Process(), out = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [source.path]
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if ["invalid-new", "linked-new"].contains(mode) {
            #expect(process.terminationStatus != 0 && bytes.isEmpty)
        } else {
            #expect(process.terminationStatus == 0)
            let expected = mode == "legacy" ? "/legacy/games" : (mode == "library" ? "/reviewed/pages/000" : "/usr/share/games")
            #expect(String(decoding: bytes, as: UTF8.self) == expected + "\n")
        }
        #expect(FileManager.default.fileExists(atPath: legacy.path) == (mode == "legacy"))
    }
}
