import Foundation
import SwiftHakchiCore

/// Fixed read-only check that the interrupted selection file is gone after restart.
enum SNESLibraryRollbackPendingCommands {
    struct Request:Sendable {
        let script:String,id:UUID,challenge:UUID,contextSHA256:String,hwid:String
        var receipt:Data {Data("SWIFTHAKCHI_SNES_ROLLBACK_PENDING_ABSENT_V1 \(challenge.uuidString)\nCONTEXT \(contextSHA256)\nHWID \(hwid)\nMENU \(id.uuidString)\nEND\n".utf8)}
    }
    static func prepare(id:UUID,context:String,hwid:String,runtime:String,challenge:UUID)throws->Request {
        var script=try SNESLibraryInventoryCommands.prefix(context:context,hwid:hwid,runtime:runtime)
        let request=Request(script:"",id:id,challenge:challenge,contextSHA256:context,hwid:hwid)
        script += "for p in \"${N%/*}\" \"$N\" \"$N/descriptions\";do data_directory \"$p\";done\n"
        script += "test ! -e \"$N/descriptions/\(id.uuidString).rollback\" && test ! -L \"$N/descriptions/\(id.uuidString).rollback\" || exit 1\n"
        script += "no_game\nprintf '\(String(decoding:request.receipt,as:UTF8.self))'\n"
        return .init(script:script,id:id,challenge:challenge,contextSHA256:context,hwid:hwid)
    }
}
struct SNESLibraryRollbackPendingReceipt:Sendable {
    let raw:Data,id:UUID,contextSHA256:String,hwid:String
    init(_ raw:Data,request:SNESLibraryRollbackPendingCommands.Request)throws {
        guard raw==request.receipt else {throw SNESLibraryInventory.failure()}
        self.raw=raw;id=request.id;contextSHA256=request.contextSHA256;hwid=request.hwid
    }
}
