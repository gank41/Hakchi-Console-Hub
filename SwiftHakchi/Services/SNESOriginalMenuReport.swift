import Foundation
import SwiftHakchiCore

enum SNESOriginalMenuState: String, Sendable { case preMenu = "pre-menu", ready }
struct SNESOriginalMenuExpectation: Sendable {
    let binding: SNESRuntimeBinding, nonce: String, filesSHA256: String, sourceFilesSHA256: String, componentsSHA256: String
    func validate() throws {
        try binding.validate()
        guard UUID(uuidString: nonce)?.uuidString == nonce,
              [filesSHA256,sourceFilesSHA256,componentsSHA256].allSatisfy({ $0.count == 64 && SNESRuntimeBinding.hex($0) }) else { throw SNESRuntimeBinding.failure() }
    }
}
extension PreparedSNESOriginalMenu {
    var expectation: SNESOriginalMenuExpectation {
        .init(binding: material.binding, nonce: nonce, filesSHA256: filesSHA256, sourceFilesSHA256: sourceFilesSHA256, componentsSHA256: componentsSHA256)
    }
}
struct SNESOriginalMenuReport: Sendable {
    let raw: Data, baseline: Data
    init(_ raw: Data, expected: SNESOriginalMenuExpectation, challenge: UUID, state: SNESOriginalMenuState) throws {
        try expected.validate()
        guard raw.count <= 65536 else { throw SNESRuntimeBinding.failure() }
        let bytes = Array(raw); var cursor = 0
        func line() throws -> String {
            let limit = min(bytes.count,cursor+1024)
            guard cursor < limit, let end = bytes[cursor..<limit].firstIndex(of:10), bytes[cursor..<end].allSatisfy({ (32...126).contains($0) }) else { throw SNESRuntimeBinding.failure() }
            let value = String(decoding:bytes[cursor..<end],as:UTF8.self);cursor=end+1;return value
        }
        guard try line() == "SWIFTHAKCHI_SNES_ORIGINAL_MENU_V1" else { throw SNESRuntimeBinding.failure() }
        var fields: [String:String] = [:]
        for _ in 0..<21 {
            let text = try line()
            guard let separator = text.firstIndex(of:"=") else { throw SNESRuntimeBinding.failure() }
            let key = String(text[..<separator]),value = String(text[text.index(after:separator)...])
            guard fields[key] == nil else { throw SNESRuntimeBinding.failure() };fields[key]=value
        }
        let constants = ["NONCE":expected.nonce,"CHALLENGE":challenge.uuidString,"KERNEL":"3.4.113","BOARD":"dp-shvc","REGION":"USA","HWID":expected.binding.expectedHWID,
            "FILES_SHA":expected.filesSHA256,"SOURCE_FILES_SHA":expected.sourceFilesSHA256,"COMPONENTS_SHA":expected.componentsSHA256,
            "STATE":state.rawValue,"BLOCKS":"readonly","MODULES":"clvcon,mali,sunxi_keyboard,sunxi_knob","CONTROLLER":"loaded-arguments:1,195,2,194",
            "BINDS":"verified","DEVICES":"ready","USB":"verified-model-3","PROFILE":"temporary","SUPERVISOR":"busybox-init"]
        func number(_ key:String) -> Int? { guard let text=fields[key],let n=Int(text),String(n)==text else { return nil };return n }
        guard Set(fields.keys)==Set(constants.keys).union(["TAINT","MCP_PID","DAEMON_PID"]),constants.allSatisfy({fields[$0.key]==$0.value}),
              ["0","4096"].contains(fields["TAINT"]),let daemon=number("DAEMON_PID"),(2...4_194_304).contains(daemon),let mcp=number("MCP_PID"),
              state == .preMenu ? mcp == 0 : ((2...4_194_304).contains(mcp) && mcp != daemon) else { throw SNESRuntimeBinding.failure() }
        let header=try line().components(separatedBy:" ")
        guard header.count==3,header[0]=="BASELINE",let count=Int(header[1]),String(count)==header[1],(1...32768).contains(count),
              header[2].count==64,SNESRuntimeBinding.hex(header[2]),count < bytes.count-cursor else { throw SNESRuntimeBinding.failure() }
        let baseline=Data(bytes[cursor..<cursor+count]);cursor+=count
        guard BackupManifest.digest(baseline)==header[2],baseline.starts(with:Data("SNES_PRE_MENU_BEGIN\nPOWER_SWITCH=1\n".utf8)),
              baseline.suffix(18)==Data("SNES_PRE_MENU_END\n".utf8),bytes[cursor]==10 else { throw SNESRuntimeBinding.failure() }
        cursor+=1
        guard try line()=="MOUNTS_BEGIN" else { throw SNESRuntimeBinding.failure() }
        let mounts=try (0..<17).map { _ in try line() }
        try SNESTemporaryMenuReport.validateMounts(mounts)
        guard try line()=="MOUNTS_END",try line()=="END",cursor==bytes.count else { throw SNESRuntimeBinding.failure() }
        self.raw=raw;self.baseline=baseline
    }
}
