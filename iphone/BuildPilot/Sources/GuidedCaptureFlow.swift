import Foundation

/// The capture-closure loop: scan → review the wall-loop assessment →
/// targeted rescans until the loop closes (or the user knowingly finishes
/// with the incomplete flag). A pure state machine in the VisitSetupFlow
/// mould — no ARKit, no SwiftUI — so the ordering rules are unit-testable:
/// a rescan can only start from the review screen, a clean finish is only
/// reachable when the loop actually closed, and finishing with an open loop
/// is always *possible* (never trap a user in a customer's living room) but
/// never *silent* — the UI must surface the not-quotable consequence.
enum GuidedCapturePhase: Equatable {
    case scanning
    case review
    case rescanning
}

struct GuidedCaptureFlow: Equatable {
    private(set) var phase: GuidedCapturePhase = .scanning
    private(set) var assessment: WallLoopStatus = .noWalls
    private(set) var rescanCount = 0

    /// RoomPlan finished (initial scan or a rescan): record the assessment
    /// and show the review. Ignored while already reviewing.
    mutating func scanEnded(_ status: WallLoopStatus) {
        guard phase == .scanning || phase == .rescanning else { return }
        assessment = status
        phase = .review
    }

    /// "Scan the gap": only from review, and only when there is a gap.
    @discardableResult
    mutating func rescan() -> Bool {
        guard phase == .review, !loopClosed else { return false }
        rescanCount += 1
        phase = .rescanning
        return true
    }

    var loopClosed: Bool {
        if case .closed = assessment { return true }
        return false
    }

    /// The gaps to point the user at, when the loop is open.
    var openEnds: [OpenWallEnd] {
        if case .open(let ends, _) = assessment { return ends }
        return []
    }

    /// Finish with no caveats — the loop closed.
    var canFinishCleanly: Bool { phase == .review && loopClosed }

    /// Finish anyway — allowed, but the visit will carry the incomplete flag
    /// and the estimate will not be quotable until verified (Decision 34).
    var canFinishFlagged: Bool { phase == .review && !loopClosed }
}
