import Foundation
import USBBridge

/// Fixed word-width reads: ROM byte copies truncate this SoC's identity registers.
/// Uses only the A33/R16 scratch region; no caller-selected address or code.
enum FELSIDReader {
    static let address:UInt32=0x1000
    // Independently assembled ARMv7: four LDR/STR pairs, BX LR, SID literal,
    // then16 zero result bytes. Only caller-saved R0-R2 are changed; no stack use.
    static let image:Data = {
        let words:[UInt32]=[0xe59f0024,0xe28f1024,0xe5902000,0xe5812000,
            0xe5902004,0xe5812004,0xe5902008,0xe5812008,0xe590200c,0xe581200c,
            0xe12fff1e,0x01c23800,0,0,0,0]
        return Data(words.flatMap { w in (0..<4).map {UInt8(truncatingIfNeeded:w >> ($0*8))} })
    }()
    static func read(from session:any FELSessionTransport) async throws -> Data {
        try Task.checkCancellation()
        try await session.write(address:address,data:image)
        try Task.checkCancellation()
        let initial=try await session.read(address:address,count:image.count)
        try Task.checkCancellation()
        guard initial==image else {throw FELError.readbackMismatch("hardware identity helper")}
        try await session.execute(address:address)
        try Task.checkCancellation()
        let result=try await session.read(address:address,count:image.count)
        try Task.checkCancellation()
        guard result.count==64,result.prefix(48)==image.prefix(48) else {throw FELError.readbackMismatch("hardware identity helper result")}
        return Data(result.suffix(16))
    }
}
