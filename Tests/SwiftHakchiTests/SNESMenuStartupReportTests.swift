import Foundation
import Testing
@testable import SwiftHakchi

struct SNESMenuStartupReportTests {
 let base=SNESStartupTrialExpectation(hwid:String(repeating:"1",count:32),runtimeSHA256:String(repeating:"2",count:64),wrapperSHA256:String(repeating:"3",count:64))
 @Test func menuVersionRequiresItsExtraRAMBindAndCannotReuseOldMountProof()throws {
  let expected=SNESStartupTrialExpectation(hwid:base.hwid,runtimeSHA256:base.runtimeSHA256,wrapperSHA256:base.wrapperSHA256,deviceVersion:0x6a05,menuWrapperSHA256:String(repeating:"4",count:64)),id=UUID()
  let old=String(decoding:startupTrialReportFixture(challenge:id),as:UTF8.self)
  let menu=old.replacingOccurrences(of:"MOUNTS_END",with:"tmpfs /etc/init.d/S81clover-mcp tmpfs rw 0 0\nMOUNTS_END")
  _=try SNESStartupTrialReport(Data(menu.utf8),expected:expected,challenge:id)
  let active=menu.replacingOccurrences(of:"MOUNTS_END",with:"tmpfs /usr/share/applications/clover-mcp.desktop tmpfs rw 0 0\nMOUNTS_END")
  _=try SNESStartupTrialReport(Data(active.utf8),expected:expected,challenge:id)
  #expect(throws:(any Error).self) {try SNESStartupTrialReport(Data(old.utf8),expected:expected,challenge:id)}
  #expect(throws:(any Error).self) {try SNESStartupTrialReport(Data(menu.utf8),expected:base,challenge:id)}
  #expect(throws:(any Error).self) {try SNESStartupTrialReport(Data(active.replacingOccurrences(of:"clover-mcp.desktop tmpfs rw",with:"clover-mcp.desktop ext4 rw").utf8),expected:expected,challenge:id)}
 }
 @Test func distinguishesKnownMenuUSBVersionFromUnrelatedDevices()throws {
  let d=RecoveryProbeUSBDevice(vendorID:0x1f3a,productID:0xefe8,deviceVersion:0x6a05,deviceClass:0,locationID:42,product:"Swift Hakchi SNES Startup",registryEntryID:3)
  _=try SNESStartupTrialUSBPolicy.nativeIdentity(d)
  #expect(try SNESStartupTrialUSBPolicy.after([d],original:startupTrialFEL)==d)
  let invalid=SNESStartupTrialExpectation(hwid:base.hwid,runtimeSHA256:base.runtimeSHA256,wrapperSHA256:base.wrapperSHA256,deviceVersion:0x6a05)
  #expect(throws:(any Error).self) {try invalid.validate()}
 }
}
