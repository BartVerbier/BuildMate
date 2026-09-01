import Foundation

/// The pre-scan sequence: customer details → walk-through light check →
/// light report → Start Visit. A pure state machine (no SwiftUI, no ARKit)
/// so the screen order is unit-testable: the light gate must not run while
/// details are being typed, and Start Visit must not be reachable before
/// the report has been shown.
enum VisitSetupStep: Equatable {
    case details
    case lightCheck
    case report
}

struct VisitSetupFlow: Equatable {
    private(set) var step: VisitSetupStep = .details

    /// "Next" on the details form. Refuses while the customer is invalid —
    /// the light check must not start early.
    @discardableResult
    mutating func advanceToLightCheck(customerValid: Bool) -> Bool {
        guard step == .details, customerValid else { return false }
        step = .lightCheck
        return true
    }

    /// The survey reached a terminal gate state (complete, or unavailable
    /// via the fail-open paths): show the report. Only valid mid-check.
    mutating func surveyEnded() {
        guard step == .lightCheck else { return }
        step = .report
    }

    /// Back from the light check to edit details (the gate is stopped by
    /// the caller).
    mutating func backToDetails() {
        guard step == .lightCheck else { return }
        step = .details
    }

    /// "Check Light Again" from the report: re-walk.
    mutating func reWalk() {
        guard step == .report else { return }
        step = .lightCheck
    }
}


/// The two gates in front of Start Visit, as one pure rule so it is
/// unit-testable and cannot quietly regress: the light check must allow it,
/// and the customer's recording consent must be confirmed (the conversation
/// is recorded — an App Review requirement and, in much of the EU, a legal
/// one). Neither gate may ever be bypassed by UI restructuring.
enum VisitStartRules {
    static func canStart(lightAllowsStart: Bool, recordingConsentConfirmed: Bool) -> Bool {
        lightAllowsStart && recordingConsentConfirmed
    }
}
