import Foundation

/// Reject ambiguous object keys in bounded JSON that Foundation has already
/// parsed. Escaped spellings are decoded before comparing names.
enum SNESStrictJSONKeys {
    static func validate(_ data:Data)throws {
        guard !data.isEmpty,data.count<=65536 else {throw SNESRuntimeBinding.failure()}
        _=try JSONSerialization.jsonObject(with:data,options:[.fragmentsAllowed])
        var scanner=Scanner(bytes:Array(data))
        try scanner.value(depth:0)
        scanner.whitespace()
        guard scanner.index==scanner.bytes.count else {throw SNESRuntimeBinding.failure()}
    }
    private struct Scanner {
        let bytes:[UInt8]
        var index=0
        mutating func whitespace() {
            while index<bytes.count && [9,10,13,32].contains(bytes[index]) {index += 1}
        }
        mutating func take(_ byte:UInt8)->Bool {
            whitespace()
            guard index<bytes.count,bytes[index]==byte else {return false}
            index += 1;return true
        }
        mutating func string()throws->String {
            whitespace()
            guard index<bytes.count,bytes[index]==34 else {throw SNESRuntimeBinding.failure()}
            let start=index;index += 1
            while index<bytes.count {
                let byte=bytes[index];index += 1
                if byte==34 {return try JSONDecoder().decode(String.self,from:Data(bytes[start..<index]))}
                if byte==92 {
                    guard index<bytes.count else {throw SNESRuntimeBinding.failure()}
                    index += 1
                }
            }
            throw SNESRuntimeBinding.failure()
        }
        mutating func value(depth:Int)throws {
            guard depth<=64 else {throw SNESRuntimeBinding.failure()}
            whitespace();guard index<bytes.count else {throw SNESRuntimeBinding.failure()}
            switch bytes[index] {
            case 123:
                index += 1;whitespace()
                if take(125) {return}
                var keys=Set<String>()
                while true {
                    let key=try string()
                    guard keys.insert(key).inserted,take(58) else {throw SNESRuntimeBinding.failure()}
                    try value(depth:depth+1)
                    if take(125) {return}
                    guard take(44) else {throw SNESRuntimeBinding.failure()}
                }
            case 91:
                index += 1;whitespace()
                if take(93) {return}
                while true {
                    try value(depth:depth+1)
                    if take(93) {return}
                    guard take(44) else {throw SNESRuntimeBinding.failure()}
                }
            case 34:
                _=try string()
            default:
                let start=index
                while index<bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) {index += 1}
                guard index>start else {throw SNESRuntimeBinding.failure()}
            }
        }
    }
}
