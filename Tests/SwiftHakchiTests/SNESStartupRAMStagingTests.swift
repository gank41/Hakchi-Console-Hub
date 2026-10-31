import Foundation
import Testing
import os
@testable import SwiftHakchi

struct SNESStartupRAMStagingTests {
 @Test(arguments:["none","observe","create","image","stock","verify"])
 func changedSourceBetweenRAMStepsStopsBeforeTheNextStep(_ point:String) async throws {
  let state=OSAllocatedUnfairLock(initialState:(valid:true,events:[String]()))
  let validate:@Sendable ()throws->Void={try state.withLock {if !$0.valid {throw SNESRuntimeBinding.failure()}}}
  let step:@Sendable (String)async throws->Void={name in state.withLock{$0.events.append(name);if name==point {$0.valid=false}}}
  if point=="none" {
   try await SNESStartupRAMStaging.run(validate:validate,observe:{try await step("observe")},create:{try await step("create")},uploadImage:{try await step("image")},uploadStock:{try await step("stock")},verify:{try await step("verify")})
   #expect(state.withLock{$0.events}==["observe","create","image","stock","verify","observe"])
  } else {
   await #expect(throws:(any Error).self) {try await SNESStartupRAMStaging.run(validate:validate,observe:{try await step("observe")},create:{try await step("create")},uploadImage:{try await step("image")},uploadStock:{try await step("stock")},verify:{try await step("verify")})}
   let order=["observe","create","image","stock","verify"],last=try #require(order.firstIndex(of:point));#expect(state.withLock{$0.events}==Array(order[...last]))
  }
 }
}
