import Foundation

/// What one quota cycle has already sent, or planned to send, to each
/// account, so every rule that puts sessions on an account in that cycle
/// charges it for all the others instead of judging each session alone.
///
/// Each session is charged to one account (its "lane"), a later charge
/// replacing an earlier one: the weighted tokens per hour it is expected to
/// use there from when it starts (now for a placement, a move or a release
/// from a pause; the lane's reset for a planned wait or a session a cache
/// wait holds there), and the tokens its arrival writes into that lane's
/// cache (none on the account it already runs on).
///
/// Written and read, in cycle order, by `AppState.holdSessionsForImminentReset`
/// (the sessions held on their account until its reset), lane admission and
/// the stranded placement (`AppState.strandedPlacements`, through
/// `SessionPacer.admitToLanes` and `place`), the held-session plans
/// (`HeldSessionPlan.planTogether`), the slot path's fallback for an
/// account that can no longer serve (`AppState.serveSessionSlots`), the
/// sessions a pause at a limit releases (`AppState.limitPauseScope`) and
/// the sessions resumed as capacity allows (`AppState.admitPausedSessions`).
/// Kept per provider in `AppState.laneLedgers`; `runQuotaCycle` starts it
/// afresh, so a charge lasts one cycle and the next weighs every session
/// again where it then runs.
struct LaneLedger: Equatable {
    /// Why a session is charged to its lane.
    enum Kind: Equatable {
        /// Placed or moved there this cycle.
        case placed
        /// Planned to start there at the lane's reset.
        case planned
        /// Held on its own account until that account's reset.
        case held
        /// Released from a pause onto the account it runs on.
        case released
    }

    struct Charge: Equatable {
        var session: String
        var lane: UUID
        var tokensPerHour: Double
        /// Weighted tokens its arrival writes into the lane's cache.
        var arrivalTokens: Double = 0
        /// When it starts using the lane.
        var from: Date
        var kind: Kind
    }

    /// When the cycle that keeps this ledger began.
    var startedAt: Date
    private(set) var charges: [String: Charge] = [:]

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Charges `charge.lane` for its session, in place of any charge the
    /// session had.
    mutating func charge(_ charge: Charge) {
        charges[charge.session] = charge
    }

    mutating func remove(_ session: String) {
        charges[session] = nil
    }

    func charge(of session: String) -> Charge? { charges[session] }

    /// The lane's charges, by session.
    func charges(on lane: UUID) -> [Charge] {
        charges.values.filter { $0.lane == lane }.sorted { $0.session < $1.session }
    }

    /// The lane's charges as loads `CapacityOutlook.carries` and
    /// `CapacityOutlook.servedAlone` step through, less `session`'s own.
    func loads(on lane: UUID, excluding session: String? = nil) -> [CapacityOutlook.Load] {
        charges(on: lane).filter { $0.session != session }.map {
            CapacityOutlook.Load(from: $0.from, tokensPerHour: $0.tokensPerHour, arrivalTokens: $0.arrivalTokens)
        }
    }

    /// Weighted tokens per hour the lane's charges use at `time`.
    func tokensPerHour(on lane: UUID, at time: Date) -> Double {
        charges(on: lane).filter { $0.from <= time }.reduce(0) { $0 + $1.tokensPerHour }
    }

    /// `running` less the sessions this ledger charges: those are counted
    /// on their lane, from when they start there, and not also where they
    /// ran before.
    func excluding(_ running: [SessionPacer.RebalanceSession]) -> [SessionPacer.RebalanceSession] {
        running.filter { charges[$0.id] == nil }
    }

    /// The charges on `lanes` started by `now`, as sessions running there,
    /// for the pacer's rules that weigh what each account already carries
    /// (`SessionPacer.admitToLanes`, `place`). Their arrivals are
    /// `arrivalTokens(on:by:)`.
    func started(by now: Date, on lanes: Set<UUID>) -> [SessionPacer.RebalanceSession] {
        charges.values.filter { lanes.contains($0.lane) && $0.from <= now }.sorted { $0.session < $1.session }.map {
            SessionPacer.RebalanceSession(id: $0.session, account: $0.lane, tokensPerHour: $0.tokensPerHour,
                                          contextTokens: 0, model: nil, movable: false)
        }
    }

    /// Weighted tokens the arrivals charged to `lane` and started by `now`
    /// write into its cache.
    func arrivalTokens(on lane: UUID, by now: Date) -> Double {
        charges(on: lane).filter { $0.from <= now }.reduce(0) { $0 + $1.arrivalTokens }
    }
}
