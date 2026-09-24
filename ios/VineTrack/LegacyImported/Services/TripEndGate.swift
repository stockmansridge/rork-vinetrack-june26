import Foundation

/// Why a manual End Trip request cannot proceed yet.
///
/// Every case here is a *real* product prerequisite that the operator can
/// clear themselves, and each one carries the exact action required. There is
/// deliberately no case for planned-path state: see `TripEndGate`.
nonisolated enum TripEndBlocker: Equatable, Sendable {
    /// A spray tank is still open and must be ended so its end time and end
    /// row are recorded against the session.
    case activeTank(tankNumber: Int)
    /// A fill timer is still running. Ending the trip now would leave the
    /// session with a `fillStartTime` and no `fillEndTime`.
    case fillingTank(tankNumber: Int?)

    /// Operator-facing explanation of what is holding the trip open.
    var reason: String {
        switch self {
        case let .activeTank(number):
            return "Tank \(number) is still running."
        case let .fillingTank(number):
            if let number {
                return "The fill timer for Tank \(number) is still running."
            }
            return "A tank fill timer is still running."
        }
    }

    /// The exact action the operator must take to clear the blocker.
    var requiredAction: String {
        switch self {
        case .activeTank:
            return "Tap End Tank to close it, then end the trip."
        case .fillingTank:
            return "Tap Stop Fill to finish the fill, then end the trip."
        }
    }

    /// Single message for an alert: never just "can't end trip".
    var message: String { "\(reason) \(requiredAction)" }
}

/// Why the final trip state could not be written to the device.
nonisolated enum TripEndPersistenceError: LocalizedError, Equatable, Sendable {
    /// The trip is no longer in the local store, or no vineyard is selected.
    case tripUnavailable

    var errorDescription: String? {
        switch self {
        case .tripUnavailable:
            return "The trip could not be found on this device."
        }
    }
}

/// The result of asking whether a trip may be ended right now.
nonisolated enum TripEndDecision: Equatable, Sendable {
    case allowed
    case blocked(TripEndBlocker)

    var isAllowed: Bool { self == .allowed }

    var blocker: TripEndBlocker? {
        if case let .blocked(blocker) = self { return blocker }
        return nil
    }
}

/// The single authority on whether a manual End Trip may proceed.
///
/// ## Why this exists
///
/// Free Drive trips intentionally carry no planned path: `plannedPath` is nil,
/// `rowSequence` is empty, `sequenceIndex` is 0/0, planned progress is 0% and
/// the accumulated planned-path distance stays at 0 m because there is no
/// planned row to accumulate *against*. Those zeroes describe the absent plan,
/// not the trip — a Free Drive trip with 6,655 recorded GPS points and 29
/// completed paths reports every one of them.
///
/// This gate therefore takes **no** planned-path input at all. `plannedPath`,
/// `rowSequence`, `sequenceIndex`, path length, planned progress, accumulated
/// planned distance, current row, row lock, corridor status, GPS accuracy and
/// speed are all absent from `evaluate` by design, so no future edit can
/// reintroduce a planned-path or movement precondition on manual termination
/// without deleting a test. Ending a trip is an act of operator intent; it is
/// not a reward for completing a route.
///
/// The only things that may hold a trip open are unfinished *records* that
/// ending would corrupt — an open tank session or a running fill timer — and
/// both are clearable by the operator from the tank bar.
nonisolated enum TripEndGate {

    /// Decide whether a manual End Trip may proceed.
    ///
    /// - Parameters:
    ///   - activeTankNumber: the currently open spray tank, if any.
    ///   - isFillingTank: whether a fill timer is currently running.
    ///   - fillingTankNumber: the tank the fill timer belongs to, if known.
    static func evaluate(
        activeTankNumber: Int?,
        isFillingTank: Bool,
        fillingTankNumber: Int?
    ) -> TripEndDecision {
        if let activeTankNumber {
            return .blocked(.activeTank(tankNumber: activeTankNumber))
        }
        if isFillingTank {
            return .blocked(.fillingTank(tankNumber: fillingTankNumber))
        }
        return .allowed
    }

    /// Convenience overload taking the trip itself.
    static func evaluate(trip: Trip) -> TripEndDecision {
        if let open = trip.tankSessions.first(where: { TankSessionLifecycle.isOpenSpray($0) }) {
            return .blocked(.activeTank(tankNumber: open.tankNumber))
        }
        if let fill = trip.tankSessions.first(where: { $0.fillStartTime != nil && $0.fillEndTime == nil }) {
            return .blocked(.fillingTank(tankNumber: fill.tankNumber))
        }
        return evaluate(
            activeTankNumber: trip.activeTankNumber,
            isFillingTank: trip.isFillingTank,
            fillingTankNumber: trip.fillingTankNumber
        )
    }
}

/// The outcome of a manual End Trip attempt.
///
/// `endTrip` returns this rather than silently returning, so no caller can
/// present a dead button: every non-`ended` case carries text to show.
nonisolated enum TripEndOutcome: Equatable, Sendable {
    /// The trip is durably ended locally. Any server work is queued.
    case ended
    /// A real prerequisite is outstanding; the operator can clear it.
    case blocked(TripEndBlocker)
    /// Local persistence failed. The trip is STILL ACTIVE and intact.
    case persistenceFailed(String)
    /// There was no active trip to end.
    case noActiveTrip

    var isEnded: Bool { self == .ended }

    /// Message to show the operator, or nil when the trip ended cleanly.
    var operatorMessage: String? {
        switch self {
        case .ended:
            return nil
        case let .blocked(blocker):
            return blocker.message
        case let .persistenceFailed(detail):
            return "Couldn't save the finished trip to this device, so it's still running and nothing has been lost. \(detail)"
        case .noActiveTrip:
            return "This trip is no longer active."
        }
    }
}
