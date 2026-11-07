import Foundation
import Testing
import os
@testable import SwiftHakchi

actor SNESFirmwareShellFake:SNESFirmwareShell {
    let material:SNESFirmwareMaterial,fault:String
    var uploads=0,writeCalls=0,creates=0,commands:[String]=[]
    var hashLimits: [Int]?
    let hashChallenge:UUID?,reviewedHash:String?
    let onFirmwareWrite:(@Sendable () async -> Void)?
    private var holdHash = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var holdFirmwareBefore=false,holdFirmwareAfter=false
    private var firmwareContinuation:CheckedContinuation<Void,Never>?
    private var firmwareGate:SNESFirmwareDispatchGate?
    var firmwareWaiting:Bool {firmwareContinuation != nil}
    var firmwareGateInvalidated:Bool {firmwareGate?.isInvalidated ?? false}
    func holdFirmwareDispatch(before:Bool) {holdFirmwareBefore=before;holdFirmwareAfter = !before}
    func releaseFirmwareDispatch() {holdFirmwareBefore=false;holdFirmwareAfter=false;let pending=firmwareContinuation;firmwareContinuation=nil;pending?.resume()}
    var hashWaiting: Bool { continuation != nil }
    func holdNextHash() { holdHash = true }
    func releaseHash() { holdHash = false; let pending = continuation; continuation = nil; pending?.resume() }
    init(material:SNESFirmwareMaterial,fault:String,hashChallenge:UUID?=nil,reviewedHash:String?=nil,onFirmwareWrite:(@Sendable () async -> Void)?=nil){self.material=material;self.fault=fault;self.hashChallenge=hashChallenge;self.reviewedHash=reviewedHash;self.onFirmwareWrite=onFirmwareWrite}
    func executeBounded(_ command:String,stdoutLimit:Int,stderrLimit:Int,timeout:Int) async -> BoundedSSHExecution {
        commands.append(command)
        let output:String
        if command.contains("SWIFTHAKCHI_SNES_DATA_HASH_V1"),
           let challenge=hashChallenge ?? command.components(separatedBy:"'").compactMap(UUID.init(uuidString:)).first {
            hashLimits = [stdoutLimit,stderrLimit,timeout]
            if holdHash { holdHash = false; await withCheckedContinuation { continuation = $0 } }
            let count=(try? material.source.dataSnapshotPlan().byteCount) ?? 0
            let responseChallenge = fault == "hash-challenge" ? UUID() : challenge
            output="SWIFTHAKCHI_SNES_DATA_HASH_V1 \(responseChallenge.uuidString) \(count) \(reviewedHash ?? String(repeating:"a",count:64))\n"
        }
        else if command.contains("SWIFTHAKCHI_SNES_FIRMWARE_CREATED_V1") {creates+=1;output=fault=="stage" ? "wrong\n":SNESFirmwareCommands.created(material.id)}
        else if command.contains("SWIFTHAKCHI_SNES_FIRMWARE_STAGED_V1") {output=SNESFirmwareCommands.staged(material)}
        else {let writing=command.contains("replace-active");if writing {writeCalls+=1};output=SNESFirmwareCommands.marker(material,writing:writing)+((fault=="extra" || (writing && fault=="write-extra")) ? "extra\n":"")}
        return .init(stdout:Data(output.utf8),stderr:Data(),exitCode:(fault=="exit" || fault=="hash-exit" || (writeCalls>0 && fault=="write-exit")) ? 1:0,transportCode:(fault=="transport" || fault=="hash-transport" || (writeCalls>0 && fault=="write-transport")) ? -43:0)
    }
    func uploadExclusive(data:Data,to remotePath:String,timeout:Int)throws {uploads+=1;if fault=="upload" {throw SNESRuntimeBinding.failure()}}
    func executeFirmwareBounded(_ command:String,stdoutLimit:Int,stderrLimit:Int,timeout:Int,gate:SNESFirmwareDispatchGate) async throws -> BoundedSSHExecution {
        guard command==SNESFirmwareCommands.invoke(material,writing:true) else {throw SNESRuntimeBinding.failure()}
        firmwareGate=gate
        if holdFirmwareBefore {holdFirmwareBefore=false;await withCheckedContinuation {firmwareContinuation=$0}}
        let result=try gate.dispatch {
            commands.append(command);writeCalls += 1
            let output=SNESFirmwareCommands.marker(material,writing:true)+((fault=="extra" || fault=="write-extra") ? "extra\n":"")
            return BoundedSSHExecution(stdout:Data(output.utf8),stderr:Data(),
                exitCode:(fault=="exit" || fault=="write-exit") ? 1:0,
                transportCode:(fault=="transport" || fault=="write-transport") ? -43:0)
        }
        if result.transportCode == 0 && result.exitCode == 0 { await onFirmwareWrite?() }
        if holdFirmwareAfter {holdFirmwareAfter=false;await withCheckedContinuation {firmwareContinuation=$0}}
        return result
    }
}
@Suite(.serialized)
struct NativeSNESFirmwareIOTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func reviewedSessionRejectsLegacyMaterial() async throws {
        let material=try await SNESFirmwareFixtureCache.shared.value(),checked=try await SNESFirmwareGuardFixtureCache.shared.value()
        let base=SNESFirmwareFakeIO(material:material,fault:"none"),shell=SNESFirmwareShellFake(material:material,fault:"none")
        let io=try NativeSNESFirmwareIO(material:material,guard:checked,base:base,shell:shell)
        await #expect(throws:(any Error).self) { _=try await io.beginReviewedSession() }
        #expect(await base.base.events.isEmpty)
        await io.disconnect()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:[false,true])
    func concurrentDisconnectWaitsForTheOriginalClose(_ cancelWaiter:Bool) async throws {
        let material=try await SNESFirmwareFixtureCache.shared.value(),checked=try await SNESFirmwareGuardFixtureCache.shared.value()
        let base=SNESFirmwareFakeIO(material:material,fault:"none"),shell=SNESFirmwareShellFake(material:material,fault:"none")
        let io=try NativeSNESFirmwareIO(material:material,guard:checked,base:base,shell:shell)
        await base.holdNextDisconnect()
        let first=Task {await io.disconnect()}
        let deadline=ContinuousClock.now.advanced(by:.seconds(30))
        while !(await base.disconnectWaiting) && ContinuousClock.now < deadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
        guard await base.disconnectWaiting else {
            await base.releaseDisconnect();await first.value;Issue.record("The first close did not reach its barrier");return
        }
        let flags=OSAllocatedUnfairLock(initialState:(started:false,finished:false))
        let second=Task {flags.withLock {$0.started=true};await io.disconnect();flags.withLock {$0.finished=true}}
        let startDeadline=ContinuousClock.now.advanced(by:.seconds(30))
        while !flags.withLock({$0.started}) && ContinuousClock.now < startDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
        guard flags.withLock({$0.started}) else {
            await base.releaseDisconnect();await first.value;await second.value;Issue.record("The second close did not start");return
        }
        if cancelWaiter {second.cancel()}
        try? await Task.sleep(for:.seconds(1))
        #expect(!flags.withLock {$0.finished})
        await base.releaseDisconnect();await first.value;await second.value
        #expect(flags.withLock {$0.finished})
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["disconnect-before","cancel-before","competing-before","competing-header","competing-write","header-only","source-before","source-direct","disconnect-after","cancel-after"])
    func queuedFirmwareDispatchHonorsCancellationAndDisconnect(_ fault:String) async throws {
        try await runQueuedFirmwareCase(fault)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func refusedWritePermitCannotBeReplayedAcrossNativeInstances() async throws {
        try await runQueuedFirmwareCase("read-in-flight")
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["wrong-permit","simultaneous-permits"])
    func permitClaimsRejectMismatchesAndRaceOnce(_ fault:String) async throws {
        try await runQueuedFirmwareCase(fault)
    }
    private func runQueuedFirmwareCase(_ fault:String) async throws {
        let fixture=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory(),helperRoot=try testDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        defer {try? FileManager.default.removeItem(at:helperRoot)}
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let installed:SNESFirmwareMaterial,installGuard:SNESFirmwareGuard,ownedReader:URL?
        if fault.hasPrefix("source") {
            let helperDirectory=try await RecoveryBootSnapshotStore(root:helperRoot).saveSNESPortableHelpers()
            let helpers=try SNESPortableHelperPackage.load(directory:helperDirectory),p=fixture.paths
            let paths=try SNESFirmwarePaths.withHelpers(candidate:URL(fileURLWithPath:p.candidate),preflight:URL(fileURLWithPath:p.preflight),
                started:URL(fileURLWithPath:p.started),played:URL(fileURLWithPath:p.played),original:URL(fileURLWithPath:p.original),helpers:helpers)
            installed=try SNESFirmwareMaterial.install(paths:paths,recovery:inputs,id:fixture.id)
            installGuard=try SNESFirmwareGuard.prepare(installed);ownedReader=helpers.reader.location
        } else {
            installed=fixture;installGuard=try await SNESFirmwareGuardFixtureCache.shared.value();ownedReader=nil
        }
        let parentPrepared=try SNESFirmwareJournal.prepare(material:installed,root:root,guard:installGuard)
        let parent=try SNESFirmwareJournal(operation:parentPrepared.operation,reviewSHA256:parentPrepared.reviewSHA256,material:installed,guard:installGuard)
        try await parent.preflightVerified();let parentPermit=try await parent.beginWrite();try await parent.readbackVerified()
        let material=try SNESFirmwareMaterial.restore(installed:await parent.restorableInstall()),checked=try SNESFirmwareGuard.prepare(material)
        try await parent.close()
        let prepared=try SNESFirmwareJournal.prepare(material:material,root:root,guard:checked)
        let journal=try SNESFirmwareJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:material,guard:checked)
        try await journal.preflightVerified();let permit=try await journal.beginWrite()
        let libraryRoot=try testDirectory();defer {try? FileManager.default.removeItem(at:libraryRoot)}
        let base=SNESFirmwareFakeIO(material:material,fault:"none"),shell=SNESFirmwareShellFake(material:material,fault:"none")
        let io=try NativeSNESFirmwareIO(material:material,guard:checked,base:base,shell:shell,testLibraryRoot:libraryRoot)
        let before=try #require(try await base.inventory().first);try await io.boot(inputs,expected:before)
        let after=try #require(try await base.inventory().first);try await io.connect(expected:after)
        if fault=="header-only" {
            _=try await io.readDataSuperblock()
            await #expect(throws:(any Error).self) {try await io.stage()}
            let uploads=await shell.uploads,writes=await shell.writeCalls,creates=await shell.creates
            #expect(uploads==0 && writes==0 && creates==0)
            await io.disconnect();try await journal.close();return
        }
        _=try await io.readPartitions();_=try await io.readDataSuperblock();try await io.stage();try await io.verifyStaged()
        if fault=="wrong-permit" {
            await #expect(throws:(any Error).self) {try await io.replace(parentPermit)}
            #expect(await shell.writeCalls==0)
            // Rejecting a permit for a different operation does not spend it.
            try parentPermit.claim()
            try await io.replace(permit)
            #expect(await shell.writeCalls==1)
            await io.disconnect();try await journal.close();return
        }
        if fault=="simultaneous-permits" {
            // Test the shared claim directly, independently of the library lease.
            let outcomes=await withTaskGroup(of:Bool.self,returning:[Bool].self) {group in
                for _ in 0..<20 {group.addTask {do {try permit.claim();return true} catch {return false}}}
                var results:[Bool]=[]
                for await value in group {results.append(value)}
                return results
            }
            #expect(outcomes.filter{$0}.count==1)
            await #expect(throws:(any Error).self) {try await io.replace(permit)}
            #expect(await shell.writeCalls==0)
            await io.disconnect();try await journal.close();return
        }
        if fault=="read-in-flight" {
            await base.holdNextInventory()
            let read=Task {try await io.inventory()}
            let deadline=ContinuousClock.now.advanced(by:.seconds(60))
            while !(await base.inventoryWaiting) && ContinuousClock.now < deadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
            guard !Task.isCancelled,await base.inventoryWaiting else {
                await base.releaseInventory();_=try? await read.value;await io.disconnect();try await journal.close()
                Issue.record("The earlier read did not reach its barrier");return
            }
            let otherBase=SNESFirmwareFakeIO(material:material,fault:"none"),otherShell=SNESFirmwareShellFake(material:material,fault:"none")
            let other=try NativeSNESFirmwareIO(material:material,guard:checked,base:otherBase,shell:otherShell,testLibraryRoot:libraryRoot)
            let otherBefore=try #require(try await otherBase.inventory().first);try await other.boot(inputs,expected:otherBefore)
            let otherAfter=try #require(try await otherBase.inventory().first);try await other.connect(expected:otherAfter)
            _=try await other.readPartitions();_=try await other.readDataSuperblock();try await other.stage();try await other.verifyStaged()
            let outcome=OSAllocatedUnfairLock(initialState:Optional<Bool>.none)
            let write=Task {
                let refused:Bool
                do {try await io.replace(permit);refused=false} catch {refused=true}
                outcome.withLock {$0=refused}
            }
            let writeDeadline=ContinuousClock.now.advanced(by:.seconds(60))
            while outcome.withLock({$0 == nil}) && ContinuousClock.now < writeDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
            let refused=outcome.withLock {$0}
            guard let refused else {
                write.cancel();await base.releaseInventory();_=try? await read.value;await write.value
                await other.disconnect();await io.disconnect();try await journal.close()
                Issue.record("Write did not refuse while the earlier read was held");return
            }
            await write.value
            #expect(refused);#expect(await shell.writeCalls==0)
            await #expect(throws:(any Error).self) {try await other.replace(permit)}
            #expect(await otherShell.writeCalls==0)
            await base.releaseInventory();_=try? await read.value
            // The journal already recorded write intent. Even a pre-dispatch
            // refusal must not let this same permit be replayed afterward.
            await #expect(throws:(any Error).self) {try await io.replace(permit)}
            #expect(await shell.writeCalls==0)
            await other.disconnect();await io.disconnect();try await journal.close();return
        }
        await shell.holdFirmwareDispatch(before:!fault.hasSuffix("after"))
        let write=Task {try await io.replace(permit)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(60))
        while !(await shell.firmwareWaiting) && ContinuousClock.now < deadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
        guard !Task.isCancelled,await shell.firmwareWaiting else {
            write.cancel();await shell.releaseFirmwareDispatch();await io.disconnect()
            _=try? await write.value;Issue.record("Firmware dispatch did not reach the guarded boundary")
            try await journal.close();return
        }
        var closing:Task<Void,Never>?
        if fault.hasPrefix("source") {try Data([0]).write(to:try #require(ownedReader))}
        if fault.hasPrefix("cancel") {write.cancel()}
        else if fault.hasPrefix("competing") || fault=="source-before" {
            let result=OSAllocatedUnfairLock(initialState:Optional<Bool>.none)
            let competing=Task {
                let refused:Bool
                do {
                    if fault=="competing-before" || fault=="source-before" {_=try await io.readPartitions()}
                    else if fault=="competing-header" {_=try await io.readDataSuperblock()}
                    else {try await io.replace(permit)}
                    refused=false
                } catch {refused=true}
                result.withLock {$0=refused}
            }
            let deadline=ContinuousClock.now.advanced(by:.seconds(60))
            while result.withLock({$0 == nil}) && ContinuousClock.now < deadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
            guard let refused=result.withLock({$0}) else {
                write.cancel();await shell.releaseFirmwareDispatch();await io.disconnect();await competing.value
                _=try? await write.value;Issue.record("Competing console command did not return while dispatch was queued")
                try await journal.close();return
            }
            #expect(refused);await competing.value
            #expect(await shell.firmwareGateInvalidated)
        }
        else if fault=="source-direct" { }
        else {
            await base.holdNextDisconnect()
            closing=Task {await io.disconnect()}
            let closeDeadline=ContinuousClock.now.advanced(by:.seconds(60))
            while !(await base.disconnectWaiting) && ContinuousClock.now < closeDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
            #expect(await base.disconnectWaiting)
        }
        await shell.releaseFirmwareDispatch()
        await base.releaseDisconnect()
        await closing?.value
        await #expect(throws:(any Error).self) {try await write.value}
        #expect(await shell.writeCalls == (fault.hasSuffix("after") ? 1:0))
        await io.disconnect();try await journal.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil), arguments:["none","partitions","hash-challenge","hash-exit","hash-transport"])
    func fullDataHashUsesReadyFirmwareSessionWithoutWriting(_ fault:String) async throws {
        let installed=try await SNESFirmwareFixtureCache.shared.value(),installGuard=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let prepared=try SNESFirmwareJournal.prepare(material:installed,root:root,guard:installGuard)
        let parent=try SNESFirmwareJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:installed,guard:installGuard)
        try await parent.preflightVerified();_=try await parent.beginWrite();try await parent.readbackVerified()
        let m=try SNESFirmwareMaterial.restore(installed:await parent.restorableInstall()),g=try SNESFirmwareGuard.prepare(m)
        try await parent.close()
        let challenge=UUID(),base=SNESFirmwareFakeIO(material:m,fault:fault == "partitions" ? "partitions" : "none"),shell=SNESFirmwareShellFake(material:m,fault:fault,hashChallenge:challenge)
        let io=try NativeSNESFirmwareIO(material:m,guard:g,base:base,shell:shell)
        await #expect(throws:(any Error).self){_ = try await io.dataHash(challenge:challenge)}
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let before=try #require(try await base.inventory().first);try await io.boot(inputs,expected:before)
        let after=try #require(try await base.inventory().first);try await io.connect(expected:after)
        _=try await io.readDataSuperblock()
        await #expect(throws:(any Error).self){_ = try await io.dataHash(challenge:challenge)}
        _=try await io.readPartitions();_=try await io.readDataSuperblock()
        if fault != "none" {
            await #expect(throws:(any Error).self){_ = try await io.dataHash(challenge:challenge)}
            #expect(await shell.writeCalls==0)
            #expect(await shell.uploads==0)
            if fault == "partitions" { #expect(await shell.commands.isEmpty) }
            else {
                #expect(await shell.commands.count==1)
                #expect(await shell.commands.first?.contains(challenge.uuidString)==true)
                #expect(await shell.hashLimits == [256,16384,180000])
            }
            await io.disconnect()
            return
        }
        let reply=try await io.dataHash(challenge:challenge)
        #expect(try SNESDataSnapshotChunk.fullHash(reply,challenge:challenge,count:m.source.dataSnapshotPlan().byteCount)==String(repeating:"a",count:64))
        #expect(await shell.commands.count==1)
        #expect(await shell.commands.first?.contains("sha256sum /dev/nandc")==true)
        #expect(await shell.writeCalls==0)
        #expect(await shell.uploads==0)
        await shell.holdNextHash()
        let pending = Task { try await io.dataHash(challenge:challenge) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await shell.hashWaiting) && ContinuousClock.now < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        let waiting = await shell.hashWaiting
        #expect(waiting)
        if waiting {
            await #expect(throws:(any Error).self){try await io.stage()}
            await #expect(throws:(any Error).self){_ = try await io.dataHash(challenge:challenge)}
        }
        await shell.releaseHash()
        _ = try await pending.value
        await shell.holdNextHash()
        let interrupted = Task { try await io.dataHash(challenge:challenge) }
        let disconnectDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await shell.hashWaiting) && ContinuousClock.now < disconnectDeadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await shell.hashWaiting)
        await io.disconnect()
        await shell.releaseHash()
        await #expect(throws:(any Error).self){_ = try await interrupted.value}
        await #expect(throws:(any Error).self){_ = try await io.dataHash(challenge:challenge)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["none","stage","upload","transport","exit","extra","not-ready","write-extra","write-exit","write-transport"])
    func requiresCompleteStagePositiveReceiptAndOnePermit(_ fault:String) async throws {
        let installed=try await SNESFirmwareFixtureCache.shared.value(),installGuard=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        // Exercise the same native writer protocol using valid original-restoration material.
        // The historical oversized install is now deliberately refused at native construction.
        let parentPrepared=try SNESFirmwareJournal.prepare(material:installed,root:root,guard:installGuard)
        let parent=try SNESFirmwareJournal(operation:parentPrepared.operation,reviewSHA256:parentPrepared.reviewSHA256,material:installed,guard:installGuard)
        try await parent.preflightVerified();_=try await parent.beginWrite();try await parent.readbackVerified()
        let m=try SNESFirmwareMaterial.restore(installed:await parent.restorableInstall()),g=try SNESFirmwareGuard.prepare(m)
        try await parent.close()
        let prepared=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),j=try SNESFirmwareJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m,guard:g)
        try await j.preflightVerified()
        let libraryRoot=try testDirectory()
        defer{try? FileManager.default.removeItem(at:libraryRoot)}
        let base=SNESFirmwareFakeIO(material:m,fault:"none"),shell=SNESFirmwareShellFake(material:m,fault:fault),io=try NativeSNESFirmwareIO(material:m,guard:g,base:base,shell:shell,testLibraryRoot:libraryRoot)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let before=try #require(try await base.inventory().first);try await io.boot(inputs,expected:before)
        let after=try #require(try await base.inventory().first);try await io.connect(expected:after)
        if fault != "not-ready" {_=try await io.readPartitions();_=try await io.readDataSuperblock()}
        do {
            try await io.stage();try await io.verifyStaged()
            let permit=try await j.beginWrite()
            do {try await io.replace(permit);#expect(fault=="none")} catch {
                if fault == "none" { Issue.record("Unexpected fake write failure: \(error)") }
                #expect(fault.hasPrefix("write-"))
            }
            #expect(fault=="none" || fault.hasPrefix("write-"))
            await #expect(throws:(any Error).self){try await io.replace(permit)}
            await #expect(throws:(any Error).self){try await io.stage()}
        } catch {
            #expect(fault != "none")
            if fault=="transport" {
                #expect(error is SNESFirmwareCommandFailure)
                if let failure=error as? SNESFirmwareCommandFailure {#expect(failure.transport == -43 && failure.exit == 0 && !failure.diagnostic.isEmpty)}
            }
        }
        #expect(await shell.writeCalls==((fault=="none" || fault.hasPrefix("write-")) ? 1:0))
        let uploads=await shell.uploads,creates=await shell.creates
        if fault=="none" {#expect(uploads==2 && creates==1)}
        if fault=="not-ready" {#expect(uploads==0 && creates==0)}
        await io.disconnect();try await j.close()
    }
}
