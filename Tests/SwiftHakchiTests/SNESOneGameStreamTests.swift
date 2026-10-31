import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESOneGameStreamTests {
 @Test(arguments:[false,true])
 func checkedScriptDoesNotConsumeTheNextBinaryFile(_ corrupt:Bool)throws {
  let body=Data((0..<131072).map{UInt8($0%256)}),script="dd bs=1 count=131072 2>/dev/null | shasum -a 256"
  let stream=try SNESOneGameStream(script:script,body:body)
  var input=stream.input;if corrupt && !input.isEmpty {input[0]^=1}
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let inputURL=root.appendingPathComponent("input");try input.write(to:inputURL)
  let shim=root.appendingPathComponent("busybox");try Data("#!/bin/sh\ncase \"$1\" in sha256sum) shift; exec /usr/bin/shasum -a 256 \"$@\";; *) exec \"$@\";; esac\n".utf8).write(to:shim);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:shim.path)
  let process=Process(),out=Pipe(),err=Pipe(),handle=try FileHandle(forReadingFrom:inputURL);defer{try? handle.close()}
  process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=["-c",stream.command.replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:shim.path)];process.standardInput=handle;process.standardOutput=out;process.standardError=err
  try process.run();let data=out.fileHandleForReading.readDataToEndOfFile();_=err.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
  if corrupt {#expect(process.terminationStatus != 0 && data.isEmpty)} else {#expect(process.terminationStatus==0 && String(decoding:data,as:UTF8.self).hasPrefix(BackupManifest.digest(body)))}
 }
}
