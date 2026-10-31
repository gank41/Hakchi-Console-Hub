import Foundation

enum SNESLibraryWorkflowPhase: Equatable {
    enum Action: Equatable { case prepare, createBackup, copy, show, checkRestart, confirmTest, finish, discard, close, rollback, checkRollbackRestart }
    case reading, review, backupNeeded, preparing, ready, copying, copied, savingSelection, restart, checkingRestart, testing, savingBackup, readyToFinish, finishing, readyToDiscard, discarding, cancelled, complete, needsSetup, interrupted, readyToRollback, returningPrevious, rollbackRestart
    var isBusy: Bool { [.reading, .preparing, .copying, .savingSelection, .checkingRestart, .savingBackup, .finishing, .discarding, .returningPrevious].contains(self) }
    var isTerminal: Bool { self == .complete || self == .cancelled }
    var canEdit: Bool { self == .review || self == .ready }
    var action: Action? {
        switch self {
        case .readyToRollback: .rollback
        case .rollbackRestart: .checkRollbackRestart
        case .review: .prepare
        case .backupNeeded: .createBackup
        case .ready: .copy
        case .copied: .show
        case .restart: .checkRestart
        case .testing: .confirmTest
        case .readyToFinish: .finish
        case .readyToDiscard: .discard
        case .complete, .cancelled: .close
        default: nil
        }
    }
    var buttonTitle: String {
        switch action {
        case .rollback: "Return to Previous Games"
        case .checkRollbackRestart: "The Previous Menu Is Visible"
        case .prepare: "Review Changes"
        case .createBackup: "Back Up Now and Review"
        case .copy: "Step 1. Copy Games to Console"
        case .show: "Step 2. Show Updated Games"
        case .checkRestart: "The New Menu Is Visible"
        case .confirmTest: "Games Work—Continue"
        case .finish: "Step 3. Finish Sync"
        case .discard: "Remove Unfinished Copy"
        case .close: "Done"
        case nil: "Please wait…"
        }
    }
    var progressTitle: String {
        switch self {
        case .returningPrevious: "Returning to your previous menu…"
        case .reading: "Reading the console and selected games…"
        case .preparing: "Preparing sync and checking your Mac backup…"
        case .copying: "Copying new games and artwork…"
        case .savingSelection: "Saving the updated menu selection…"
        case .checkingRestart: "Checking the restarted console…"
        case .savingBackup: "Saving your tested library and current saves on the Mac…"
        case .finishing: "Removing temporary console files…"
        case .discarding: "Removing the unfinished copy…"
        default: ""
        }
    }
}
