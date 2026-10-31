import Foundation

enum GameGenieGenesis {
    static func decode(_ code:String)->(address:UInt32,value:UInt16)? {
        let alphabet=Array("ABCDEFGHJKLMNPRSTVWXYZ0123456789"),text=code.uppercased()
        guard text.range(of:"^[ABCDEFGHJKLMNPRSTVWXYZ0123456789]{4}-[ABCDEFGHJKLMNPRSTVWXYZ0123456789]{4}$",options:.regularExpression) != nil else{return nil}
        let n=text.filter{$0 != "-"}.map{UInt32(alphabet.firstIndex(of:$0)!)}
        let a=((n[1]&3)<<14)|(n[2]<<9)|((n[3]&15)<<20)|((n[3]>>4)<<8)
        let b=((n[4]>>1)<<16)|((n[6]&7)<<5)|n[7]
        let x=(n[0]<<3)|(n[1]>>2)|((n[4]&1)<<12)
        let y=((n[5]&1)<<15)|((n[5]>>1)<<8)|((n[6]>>3)<<13)
        return(a|b,UInt16(x|y))
    }
}
