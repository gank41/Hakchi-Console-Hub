import Foundation

/// A single-use boundary immediately before a firmware command enters SSH.
/// Invalidation can prevent a queued dispatch; after dispatch has been claimed,
/// the command's outcome must be treated as uncertain if acknowledgement is lost.
final class SNESFirmwareDispatchGate: @unchecked Sendable {
    private enum State {case ready,invalidated,dispatched}
    private let lock=NSLock()
    private var state:State = .ready
    private let validate:@Sendable () throws -> Void
    init(validate:@escaping @Sendable () throws -> Void = {}) {self.validate=validate}
    var isInvalidated:Bool {lock.lock();defer {lock.unlock()};return state == .invalidated}

    /// True means dispatch was prevented; false means it was already claimed.
    @discardableResult func invalidate()->Bool {
        lock.lock();defer {lock.unlock()}
        switch state {
        case .ready:state = .invalidated;return true
        case .invalidated:return true
        case .dispatched:return false
        }
    }

    /// Claim exactly once, under the same lock used by cancellation/disconnect.
    func dispatch<T>(_ operation:() throws -> T)throws->T {
        lock.lock()
        guard state == .ready else {lock.unlock();throw SNESRuntimeBinding.failure()}
        lock.unlock()
        // Validation can touch the filesystem. Do it outside the lock so a
        // cancellation or disconnect can invalidate the gate immediately.
        do {try Task.checkCancellation();try validate()}
        catch {_ = invalidate();throw error}
        lock.lock()
        guard state == .ready else {lock.unlock();throw SNESRuntimeBinding.failure()}
        if Task.isCancelled {state = .invalidated;lock.unlock();throw CancellationError()}
        state = .dispatched
        lock.unlock()
        return try operation()
    }
}
