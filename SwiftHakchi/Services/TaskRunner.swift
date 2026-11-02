import Foundation
import os

private let logger = Logger(subsystem:"com.swifthakchi.app",category:"TaskRunner")

enum TaskDisplayState { case idle, working, stopping, cancelled, failed, completed }

@MainActor
final class TaskRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var operationName = ""
    @Published private(set) var currentTask = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var hasMeasuredProgress = false
    @Published private(set) var canCancel = false
    @Published private(set) var cancelRequested = false
    @Published private(set) var error: Error?
    @Published private(set) var wasCancelled = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?
    @Published private(set) var activity = OperationActivity()
    private var currentTaskHandle: Task<Void,Never>?
    private var operationID: UUID?

    var displayState: TaskDisplayState {
        if isRunning { return cancelRequested ? .stopping : .working }
        if wasCancelled { return .cancelled }
        if error != nil { return .failed }
        return endedAt == nil ? .idle : .completed
    }

    func run(name: String, cancellable: Bool = true,
             operation: @escaping @Sendable (TaskProgressReporter) async throws -> Void) {
        guard !isRunning else { return }
        let id = UUID(); operationID = id
        operationName = OperationActivity.safe(name); currentTask = operationName
        progress = 0; hasMeasuredProgress = false; error = nil; wasCancelled = false
        cancelRequested = false; canCancel = cancellable; startedAt = Date(); endedAt = nil
        activity = OperationActivity(); activity.append(operationName)
        isRunning = true
        let reporter = TaskProgressReporter { [weak self] status,fraction,cancellable in
            guard let self, self.isRunning, self.operationID == id else { return }
            self.currentTask = OperationActivity.safe(status)
            self.activity.append(status)
            if let fraction, fraction.isFinite {
                self.progress = min(1,max(0,fraction)); self.hasMeasuredProgress = true
            } else { self.hasMeasuredProgress = false }
            if let cancellable, !self.cancelRequested { self.canCancel = cancellable }
        }
        currentTaskHandle = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await operation(reporter)
                guard let self else { return }
                self.activity.append("Complete"); self.progress = 1
            } catch is CancellationError {
                self?.wasCancelled = true; self?.currentTask = "Cancelled"
                self?.activity.append("Cancelled — operation stopped")
            } catch {
                self?.error = error
                self?.activity.append(error.localizedDescription)
                logger.error("Task failed: \(error.localizedDescription)")
            }
            guard let self else { return }
            self.endedAt = Date(); self.canCancel = false
            self.currentTaskHandle = nil; self.isRunning = false
        }
    }
    func cancel() {
        guard isRunning, canCancel, !cancelRequested else { return }
        cancelRequested = true; canCancel = false
        activity.append("Stopping — waiting for the current action to finish")
        currentTaskHandle?.cancel()
    }
}
