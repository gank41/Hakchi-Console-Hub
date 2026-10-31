import Foundation

/// SNES Game Genie byte/address permutation, checked against pinned independent decoder vectors.
enum GameGenieSNES {
    private static let alphabet=Array("DF4709156BC8A23E")
    private static let fields:[(UInt32,Int)]=[(0x003C00,10),(0x00003C,14),(0xF00000,-8),(0x000003,10),(0x00C000,-6),(0x0F0000,-12),(0x0003C0,-6)]
    static func decode(_ code:String)->(address:UInt32,value:UInt8)? {
        let code=code.uppercased()
        guard code.range(of:"^[0-9A-F]{4}-[0-9A-F]{4}$",options:.regularExpression) != nil else{return nil}
        var number:UInt32=0
        for char in code where char != "-" {guard let n=alphabet.firstIndex(of:char) else{return nil};number=(number<<4)|UInt32(n)}
        let value=UInt8(number>>24),a=number&0xFFFFFF
        let address=fields.reduce(UInt32(0)){result,field in result | (field.1>=0 ? (a&field.0)<<field.1:(a&field.0)>>(-field.1))}
        return (address,value)
    }
    static func encode(address:UInt32,value:UInt8)->String {
        var encoded=UInt32(value)<<24
        for (mask,shift) in fields {encoded |= shift>=0 ? (address>>shift)&mask:(address<<(-shift))&mask}
        let text=String((0..<8).map{alphabet[Int((encoded>>((7-$0)*4))&15)]})
        return String(text.prefix(4))+"-"+String(text.suffix(4))
    }
}
