import Foundation
import Testing
@testable import SwiftHakchi

struct SNESStrictJSONKeysTests {
    @Test func acceptsDistinctKeysInNestedObjectsAndArrays() throws {
        let bytes=Data(#"{"a":1,"array":[{"a":2},{"a":3}],"quoted\\\"key":true,"unicode":"\u263A"}"#.utf8)
        try SNESStrictJSONKeys.validate(bytes)
    }
    @Test(arguments:[
        #"{"a":1,"a":1}"#,
        #"{"a":1,"\u0061":1}"#,
        #"{"outer":{"a":1,"a":1}}"#,
        #"[{"a":1,"a":1}]"#,
        #"{"outer":{"a":1},"outer":{}}"#,
        #"{"a":1,}"#,
        #"{"a":"unterminated}"#
    ]) func rejectsDuplicateOrMalformedKeys(_ text:String) {
        #expect(throws:(any Error).self) {try SNESStrictJSONKeys.validate(Data(text.utf8))}
    }
    @Test func rejectsExcessiveNestingAndOversizedInput() {
        let deep=String(repeating:"[",count:66)+"0"+String(repeating:"]",count:66)
        #expect(throws:(any Error).self) {try SNESStrictJSONKeys.validate(Data(deep.utf8))}
        #expect(throws:(any Error).self) {try SNESStrictJSONKeys.validate(Data(repeating:0x20,count:65537))}
    }
}
