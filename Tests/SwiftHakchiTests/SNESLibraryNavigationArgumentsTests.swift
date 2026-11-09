import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryNavigationArgumentsTests {
    @Test func installedNavigationRecipeRemainsReconstructableForRecovery() {
        #expect(BackupManifest.digest(Data(SNESLibraryStartupScripts.legacyChangePage.utf8)) ==
            "902d4e3df7f94342b31f31b569c86e9d255d6e7ddd7a3b30ffa42de5d2eac3bf")
    }

    @Test func testedLaunchRecipeAndRouteRemainReconstructable() {
        #expect(BackupManifest.digest(Data(SNESLibraryStartupScripts.launchCompatibleChangePage.utf8)) == "90877fb5617b3740ec9c47fdc0a58b64a2ebd4ddc4c752051fb3742ed692af0a")
        #expect(BackupManifest.digest(Data(SNESLibraryStartupScripts.legacyRoute.utf8)) == "189d610536ff61abefcd815abee991301e362e4a88397aa5b38fe9465bc5e60e")
    }

    @Test func efficientRecipeRemainsByteExact() {
        #expect(BackupManifest.digest(Data(SNESLibraryStartupScripts.efficientChangePage.utf8))=="aa1b3e4efb747b83fe80ca443446a23953ddb0472ee3f153014d94d73fbe8808")
    }
    @Test func queuedNavigationCandidateMatchesTheSeparatelyExercisedOfflineScript() throws {
        let candidate = try SNESLibraryStartupScripts.queuedChangePageCandidate()
        #expect(BackupManifest.digest(Data(candidate.utf8)) == "9652c21ad0341a80befe2e0b1676e06b90898128e1d48c13aa9317e1b3b81c78")
        #expect(candidate != SNESLibraryStartupScripts.changePage)
        if let output = ProcessInfo.processInfo.environment["HC_SNES_QUEUED_PAGE_EXPORT"] {
            try Data(candidate.utf8).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        }
    }

    static let cloverArguments = ["--title-code", "CLV-S-00001", "--video-mode", "pixel-perfect", "--wait-transition-fd", "28", "--start-transition-fd", "31", "--finish-transition-fd", "33", "--save-data-backing-file", "/var/lib/clover/profiles/0/CLV-S-00001/cartridge.sram", "--rollback-mode", "record", "--rollback-output-dir", "/var/cache/clover//volatile/CLV-S-00001/suspendpoint0/rollback/", "--save-screenshot-on-quit", "/var/cache/clover//volatile/CLV-S-00001/suspendpoint0/state.png", "--save-time-path", "/var/cache/clover//volatile/CLV-S-00001/suspendpoint0/state.time"]
    @Test(arguments: ["direct", "clover", "title-mismatch", "unknown", "missing-value", "duplicate", "bad-fd", "large-fd", "leading-zero-fd", "bad-page", "many-options", "ignored-value"])
    func launcherArgumentsAreBoundedBeforeRuntimeOrMenuChanges(_ kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = ["001"] + (kind == "direct" ? [] : Self.cloverArguments)
        switch kind {
        case "title-mismatch": args[2] = "CLV-S-00002"
        case "unknown": args += ["--arbitrary-command", "/bin/false"]
        case "missing-value": args += ["--load-state-file"]
        case "duplicate": args += ["--title-code", "CLV-S-00001"]
        case "bad-fd": args[6] = "3;false"
        case "large-fd": args[6] = "99999999999999999"
        case "leading-zero-fd": args[6] = "028"
        case "bad-page": args[0] = "../001"
        case "many-options": args += Array(repeating: ["--load-time-path", "x"], count: 64).flatMap { $0 }
        case "ignored-value": args += ["--decorative-frame-path", "$(touch " + root.appendingPathComponent("must-not-exist").path + ")"]
        default: break
        }
        let marker = "test -d \"$R\" && test ! -L \"$R\""
        #expect(SNESLibraryStartupScripts.changePage.components(separatedBy: marker).count == 2)
        let script = SNESLibraryStartupScripts.changePage.replacingOccurrences(of: marker, with: "printf 'RUNTIME_GATE_REACHED\\n'; exit 0")
        let path = root.appendingPathComponent("handler.sh"); try Data(script.utf8).write(to: path)
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [path.path] + args
        process.standardOutput = output; process.standardError = error
        try process.run(); let stdout = output.fileHandleForReading.readDataToEndOfFile(), stderr = error.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if ["direct", "clover", "ignored-value"].contains(kind) {
            #expect(process.terminationStatus == 0, "\(String(decoding: stderr, as: UTF8.self))")
            #expect(String(decoding: stdout, as: UTF8.self) == "RUNTIME_GATE_REACHED\n")
        } else { #expect(process.terminationStatus != 0); #expect(stdout.isEmpty) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-exist").path))
    }
    @Test(arguments: ["none", "retroarch", "hc-snes-superv"])
    func experimentalStartupPageRefusesWhileCompatibilityProcessRuns(_ active: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools")
        let shim = """
        #!/bin/sh
        test "$1" = pidof || exit 1
        shift
        for name in "$@"; do if test "$name" = "$HC_TEST_PROCESS"; then echo 123; exit 0; fi; done
        exit 1
        """
        try Data(shim.utf8).write(to: tools)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tools.path)
        let next = try SNESLibraryStartupScripts.experimentalCompatibilityChangePage()
        let line = try #require(next.split(separator: "\n").first { $0.hasPrefix("no_game()") })
        let script = "set -eu\nB=" + LaunchCommand.shellQuote(tools.path) + "\n" + line + "\nno_game\nprintf ALLOWED\n"
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(["HC_TEST_PROCESS":active]) { _, new in new }
        process.standardOutput = output; try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(active == "none" ? (process.terminationStatus == 0 && String(decoding: data, as: UTF8.self) == "ALLOWED") : (process.terminationStatus != 0 && data.isEmpty))
        #expect(next != SNESLibraryStartupScripts.changePage)
    }

}
