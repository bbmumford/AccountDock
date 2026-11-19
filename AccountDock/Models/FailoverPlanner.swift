import Foundation

/// Quota knowledge about one account, as consumed by `FailoverPlanner`.
struct QuotaAccountState: Equatable {
    let id: UUID
    var usage: UsageAPIResponse?
    var observedAt: Date?
    /// Set to `observedAt` when the newest reading is one a running session
    /// reported with a response, as a status line does every few seconds;
    /// `FailoverPlanner.liveReadingShowsRoom` lets it stand over the forecast.
    var liveReadingAt: Date? = nil
    /// Session percentage consumed per hour while this account carries the workload.
    var sessionBurnPerHour: Double = 0
    /// Long-window percentage consumed per hour while this account carries the workload.
    var weeklyBurnPerHour: Double = 0
    /// Session percentage that one long-window percent buys on this plan.
    var sessionPerWeekly: Double?
    var isActive = false
    /// Usage can rise without AccountDock observing it, e.g. Claude sessions
    /// that kept the credential they started with after a switch.
    var mayBeConsumedElsewhere = false
    var credentialsUsable = true
    var workloadAvailable = true
    /// A locally elapsed reset that no provider response has confirmed yet.
    var resetUnverified = false
    /// Standard deviation of the burn rates; decisions about reaching a
    /// limit use the rate plus one deviation.
    var sessionBurnStdDev: Double = 0
    var weeklyBurnStdDev: Double = 0
    /// The account can keep serving past its plan limit on extra usage
    /// within the user's spending limit.
    var extraUsageAvailable = false
    /// Set when the provider has refused this account at its limit, through
    /// the router or in a session's transcript, since its last reading;
    /// nothing more is sent to it until a reading shows room.
    var refusedAtLimit = false
    /// Session percent per hour spent by the work that stays on this account
    /// whichever account is active: sessions in one-session slots of its
    /// own. A switch moves only the rest, the sessions on the shared
    /// sign-in, so `FailoverPlanner.plan` charges a destination the moving
    /// work beside its own slot sessions, and leaves the active account's
    /// slot sessions out of what moves.
    var stayingSessionBurnPerHour: Double = 0
    /// Session percent per million weighted tokens on this account
    /// (`AppState.accountRatio`): how much work one of its percent is. Plans
    /// differ in size, so a rate or room moved to or compared with another
    /// account goes through it (`FailoverPlanner.converted`, `tokenRoom`).
    var percentPerMillion = TurnCostModel.defaultPercentPerMillion
    /// Session percent per hour the sessions running on this account use
    /// now, at their real rates over the last few minutes, their subagents'
    /// requests included (`AppState.sessionsBurn`): a burst counts at once,
    /// where `sessionBurnPerHour`, learned from readings, follows it only
    /// over several. 0 when no session runs here. `FailoverPlanner.runway`
    /// divides the room left by it.
    var sessionsBurnPerHour: Double = 0
    /// How short `FailoverPlanner.runway` may be before the account counts
    /// as near its limit for its sessions, whatever lead a caller asks
    /// (`AppState.runwayLead`): the time a reading and a request round take.
    var runwayLead: TimeInterval = 0

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.observedAt == rhs.observedAt }
}

/// Usage extrapolated to a decision time.
struct QuotaProjection: Equatable {
    var session: Double?
    var weekly: Double?
    var sessionReset: Date?
    var weeklyReset: Date?
    var age: TimeInterval
}

enum QuotaTier: Int, Comparable {
    /// Every window is below its trigger with room to stay for the minimum dwell.
    case belowTrigger
    /// Above a trigger but still able to serve requests.
    case usable
    /// A window is at the provider limit by the account's last reading; a
    /// forecast alone never places an account here.
    case exhausted
    /// No trustworthy reading, unusable credentials or no workload entitlement.
    case ineligible

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whether an account can take work now, from `FailoverPlanner.servingVerdict`:
/// the one answer to "can it serve" and "is it near its limit" for pausing,
/// resuming, holding and pooling sessions.
enum ServingVerdict: Equatable {
    /// Below its limits, and not expected to reach one within the lead.
    case canServe
    /// Below its limits by its last reading, but forecast to reach one
    /// within the lead, or forecast past one already. New sessions are not
    /// placed here; running ones are not moved off for it.
    case nearLimit
    /// At a limit by its last reading, or refused at it by the provider.
    case atLimit
    /// No trustworthy reading, unusable credentials, an unconfirmed reset or
    /// no workload entitlement.
    case ineligible

    /// At its limit or within the lead of it.
    var atOrNearLimit: Bool { self == .nearLimit || self == .atLimit }
}

enum FailoverPlan: Equatable {
    enum StayReason: Equatable {
        case healthy
        /// Over a trigger, but no destination is below its trigger, so the
        /// active account keeps serving until a window actually reaches 100%.
        case drainingToLimit
        case holdingForImminentReset
        /// The active account is at its limit, and the sessions on the
        /// shared sign-in wait on it for a reset that comes before their
        /// prompt caches expire (`Settings.sharedSignInWaitsUntil`).
        case waitingForResetWithCache
        case dwell
        /// Every allowance is exhausted; the account serves on extra usage.
        case usingExtraUsage
    }

    enum SwitchReason: Equatable {
        case threshold
        case exhausted
        /// `advantageHours`: how much earlier the destination's latest
        /// start (`FailoverPlanner.latestStart`) comes than the active
        /// account's, or below 1 when the demand forecast decided.
        case balance(advantageHours: Double)
        case workloadUnavailable

        /// Whether intelligent balancing chose it; every other switch is
        /// failover's, at a threshold or the limit.
        var isBalance: Bool {
            if case .balance = self { return true }
            return false
        }
    }

    case stay(StayReason)
    case switchTo(UUID, SwitchReason)
    /// Fetch fresh usage for these accounts, then plan again.
    case verify([UUID])
    /// Every account is exhausted; capacity returns first on this account.
    case waitForReset(UUID, Date)
    case noCapacity
}

/// Chooses which account of one provider should carry the workload.
///
/// Rules, in order:
/// 1. A destination must be inside its trigger on *both* windows, with room
///    for the expected burn over the minimum dwell, and must carry the work
///    that moves to it for `projectedCarry` (`carries`). Accounts that may
///    be consumed elsewhere must have been read recently.
/// 2. Once the active account crosses a trigger it moves to such a
///    destination. When none exists it keeps serving up to the provider's
///    100% limit, because moving to an account that is merely less full
///    than its trigger wastes switches without adding capacity.
/// 3. At 100% it moves to the usable account with the most headroom that
///    carries the work; with none, it waits as in 4.
/// 4. When every account is exhausted it waits for the account whose limiting
///    windows all reset first.
/// 5. Balancing (optional) spends accounts in order of their latest feasible
///    start time: an allowance that resets sooner, or that the 5-hour cap can
///    no longer drain before its weekly reset, is consumed first.
struct FailoverPlanner {
    struct Settings {
        var sessionTrigger: Double
        var weeklyTrigger: Double
        var sessionQuotaMode: ProviderQuotaMode
        var loops: Bool
        var resetAware: Bool
        var preferMostCapacity: Bool
        var balancing: Bool
        var balancingAdvantageHours: Double
        var minimumDwell: TimeInterval
        var waitForImminentReset: Bool
        var resetGrace: TimeInterval
        var canSwitchProactively: Bool
        var canVerify: Bool
        /// Session percent a switch costs the destination, for re-reading
        /// the moved sessions' context into its cache.
        var switchCostPercent: Double = 0
        /// The plan-wide token cost, in session percent per million
        /// weighted tokens, that `switchCostPercent`,
        /// `inFlightReservePercent` and `demand` are counted at;
        /// `onAccount` converts them into one account's percent.
        var referenceRatio = TurnCostModel.defaultPercentPerMillion
        var allowExtraUsage = false
        /// Session percent the requests already under way may still use
        /// after a decision. The active account counts as at its limit once
        /// its headroom falls below this, so work moves before requests are
        /// refused rather than after.
        var inFlightReservePercent: Double = 0
        /// Minutes of the current burn an account at the limit's destination
        /// must be able to serve; a sliver of headroom is used up before the
        /// move has paid for itself, and the next requests are refused.
        var minimumDestinationMinutes: Double = 10
        /// Forecast long-window percent per hour; when present, balancing
        /// compares strategies by simulating the coming week.
        var demand: (@Sendable (Date) -> Double)?
        /// Weighted tokens per hour a balance switch's destination must
        /// carry for the shared sign-in at least (`carries`' `floor`): the
        /// rate of the sessions on it, and no less than a typical session's,
        /// since the sign-in also starts every session launched outside a
        /// slot. The active account's learned rate reads near nothing once
        /// it has been held at its limit, when exactly that work waits to
        /// resume, and a destination judged by it takes the sign-in with a
        /// sliver of its window left. Set by `AppState` where a balance
        /// switch or its projection is planned; 0 judges by the learned
        /// rate alone.
        var balanceMovingTokensPerHour: Double = 0
        /// When the active account's reset is due that the sessions on the
        /// shared sign-in wait on it for, since it comes before their prompt
        /// caches expire (`AppState.holdSessionsForImminentReset`); nil
        /// while they wait for none. A switch would move them and rewrite
        /// their contexts elsewhere, so `plan` makes no switch at the limit
        /// or a threshold until `AppState.accountHoldGrace` after it.
        var sharedSignInWaitsUntil: Date?

        init(
            policy: ProviderFailoverPolicy,
            provider: AIProviderType,
            canSwitchProactively: Bool = true,
            canVerify: Bool = true
        ) {
            let supportsSession = provider.capabilities.supportsSessionQuota
            sessionTrigger = supportsSession && policy.sessionEnabled ? policy.sessionThreshold : 100
            weeklyTrigger = policy.weeklyEnabled ? policy.weeklyThreshold : 100
            sessionQuotaMode = provider.capabilities.sessionQuotaMode
            loops = policy.loops
            resetAware = policy.resetAware
            preferMostCapacity = policy.preferMostCapacity
            balancing = policy.intelligentBalancingEnabled
            balancingAdvantageHours = policy.balancingMinimumAdvantageHours
            minimumDwell = policy.balancingMinimumDwellMinutes * 60
            waitForImminentReset = policy.waitForImminentReset
            resetGrace = policy.resetGraceMinutes * 60
            self.canSwitchProactively = canSwitchProactively
            self.canVerify = canVerify
        }
    }

    /// Headroom below which a window cannot carry another useful turn.
    static let minimumUsableHeadroom = 1.0
    /// Typical session percentage one weekly percent buys when a plan's own
    /// ratio has not been observed yet.
    static let defaultSessionPerWeekly = 8.0
    /// Readings of accounts whose usage can move unobserved expire this fast.
    static let liveFreshness: TimeInterval = 10 * 60
    /// An idle destination is read again before a switch once its reading is
    /// this old, whenever the request budget allows it.
    static let idleFreshness: TimeInterval = 15 * 60
    /// While no reading can be afforded, an idle account's reading is trusted
    /// for this long, because only its own resets change it.
    static let idleFallbackFreshness: TimeInterval = 6 * 60 * 60

    /// How old a reading may be for its account to take new sessions
    /// (`AppState.buildPool`). An account sessions are running on needs one
    /// within `liveFreshness` once any of them has made a request since the
    /// reading (`lastRequest`); until then nothing here has used the
    /// account, and the reading stands as an idle account's does.
    static func poolReadingLifetime(inUse: Bool, observedAt: Date, lastRequest: Date?) -> TimeInterval {
        guard inUse, let lastRequest, lastRequest > observedAt else { return idleFallbackFreshness }
        return liveFreshness
    }

    /// Whether a reading is young enough for its account to take a new
    /// session (`poolReadingLifetime`). `AppState.buildPool` reads an
    /// account whose reading is not before placing sessions on it, and
    /// gives it no new session while that reading cannot be taken: its
    /// sessions may have spent what the old reading shows left.
    static func poolReadingIsCurrent(inUse: Bool, observedAt: Date, lastRequest: Date?, now: Date) -> Bool {
        now.timeIntervalSince(observedAt) <= poolReadingLifetime(inUse: inUse, observedAt: observedAt, lastRequest: lastRequest)
    }

    /// How long past `poolReadingLifetime` an account in use stays in the
    /// pool on its last reading. The account is read before idle ones
    /// (`AppState.readUrgencyOrder`), but the request budget or a provider's
    /// cool-down can hold that reading back for minutes, and an account with
    /// most of its allowance left must not drop out of the pool meanwhile.
    static let stalePoolReadingLimit: TimeInterval = 60 * 60

    /// How far a reading of this age is trusted, for `AppState.buildPool`:
    /// 1 within `poolReadingLifetime`, then that lifetime over the
    /// reading's age, and 0 past `stalePoolReadingLimit` (or the lifetime,
    /// when that is longer), when the account leaves the pool. The reading
    /// of an account in use is grown by its learned burn over its whole
    /// age (`projection`), so its tier stays a cautious one. Below 1 the
    /// account keeps the sessions it serves but takes no new one
    /// (`poolReadingIsCurrent`).
    static func poolReadingConfidence(inUse: Bool, observedAt: Date, lastRequest: Date?, now: Date) -> Double {
        let lifetime = poolReadingLifetime(inUse: inUse, observedAt: observedAt, lastRequest: lastRequest)
        let age = max(0, now.timeIntervalSince(observedAt))
        if age <= lifetime { return 1 }
        guard age <= max(lifetime, stalePoolReadingLimit) else { return 0 }
        return lifetime / age
    }
    static let sessionWindow = Allowance.sessionWindow
    /// The active account is judged as it will be this long from now, which
    /// covers one monitoring cycle plus the switch itself. Several agents can
    /// spend the last few percent before a trigger in under one cycle.
    static let decisionLookahead: TimeInterval = 30

    var settings: Settings

    // MARK: - Projection

    func projection(_ state: QuotaAccountState, now: Date) -> QuotaProjection? {
        guard let usage = state.usage, let observedAt = state.observedAt else { return nil }
        let age = max(0, now.timeIntervalSince(observedAt))
        let consuming = state.isActive || state.mayBeConsumedElsewhere
        func project(_ window: UsageWindow?, burn: Double) -> (Double?, Date?) {
            guard let window, let value = window.utilization else { return (nil, nil) }
            if let reset = window.resetsAtDate, reset <= now { return (nil, nil) }
            let grown = consuming ? value + burn * age / 3600 : value
            return (min(100, grown), window.resetsAtDate)
        }
        let session = project(usage.fiveHour, burn: state.sessionBurnPerHour)
        let weekly = project(usage.sevenDay, burn: state.weeklyBurnPerHour)
        return QuotaProjection(
            session: session.0, weekly: weekly.0,
            sessionReset: session.1, weeklyReset: weekly.1, age: age
        )
    }

    /// The account's last reading as it was read, without growth for its
    /// age: what `tier`, `availableAt` and `isMeasuredAtLimit` judge a limit
    /// by, so a forecast never counts as one.
    func measuredProjection(_ state: QuotaAccountState, now: Date) -> QuotaProjection? {
        var still = state
        still.isActive = false
        still.mayBeConsumedElsewhere = false
        return projection(still, now: now)
    }

    /// Whether `projection` leaves no usable room: a window within
    /// `margin` session percent of its limit (the long window within
    /// `minimumUsableHeadroom`), or too little headroom by the plan's ratio.
    func reachesLimit(_ state: QuotaAccountState, _ projection: QuotaProjection, margin: Double = minimumUsableHeadroom) -> Bool {
        guard let weekly = projection.weekly else { return false }
        if let session = projection.session, session >= 100 - margin { return true }
        return weekly >= 100 - Self.minimumUsableHeadroom || headroom(state, projection) < margin
    }

    /// Whether the account is at its limit by measurement: a refusal at the
    /// limit, or its last reading within `reserve` (the in-flight reserve
    /// `plan` holds the active account at) of a limit. A forecast that the
    /// burn has carried it there does not count: that only keeps new
    /// sessions off it (`servingVerdict`).
    func isMeasuredAtLimit(_ state: QuotaAccountState, now: Date, reserve: Double = 0) -> Bool {
        if state.refusedAtLimit { return true }
        guard let measured = measuredProjection(state, now: now) else { return false }
        return reachesLimit(state, measured, margin: reserve + Self.minimumUsableHeadroom)
    }

    /// Whether the forecast, the reading grown by the burn over its age,
    /// has the account at a limit its reading does not show. A live reading
    /// with room (`liveReadingShowsRoom`) leaves no such forecast.
    func isForecastAtLimit(_ state: QuotaAccountState, now: Date) -> Bool {
        guard let projection = projection(state, now: now), !liveReadingShowsRoom(state, now: now) else { return false }
        return reachesLimit(state, projection) && !isMeasuredAtLimit(state, now: now)
    }

    /// How long a reading a session reported with a response stands over
    /// the forecast; a working session reports one every few seconds.
    static let liveReadingLifetime: TimeInterval = 2 * 60

    /// Whether the account's newest reading is one a running session
    /// reported with a response (`QuotaAccountState.liveReadingAt`), within
    /// `liveReadingLifetime`, with every window below its trigger and no
    /// refusal since. It then wins over the forecast: the account is not
    /// triggered, not near its limit and not forecast at it, however fast
    /// the learned burn would have grown the reading. Such a reading
    /// carries the session and long windows only; a model's own weekly
    /// limit reaches the state through `AppState.plannedUsage` from the
    /// last whole reading, so a spent one still keeps the long window over
    /// its trigger here.
    func liveReadingShowsRoom(_ state: QuotaAccountState, now: Date) -> Bool {
        guard !state.refusedAtLimit, let live = state.liveReadingAt, live == state.observedAt,
              now.timeIntervalSince(live) <= Self.liveReadingLifetime,
              let measured = measuredProjection(state, now: now), let weekly = measured.weekly else { return false }
        if let session = measured.session, session >= settings.sessionTrigger { return false }
        return weekly < settings.weeklyTrigger && !reachesLimit(state, measured)
    }

    func isFresh(_ state: QuotaAccountState, now: Date) -> Bool {
        guard let observedAt = state.observedAt else { return false }
        let age = now.timeIntervalSince(observedAt)
        if state.isActive || state.mayBeConsumedElsewhere { return age <= Self.liveFreshness }
        return age <= Self.idleFreshness
    }

    /// Whether a destination can be switched to on its current reading: it is
    /// fresh, or it is idle, cannot be read now, and its reading is recent
    /// enough to trust.
    func canSwitchWithoutReading(_ state: QuotaAccountState, now: Date) -> Bool {
        if isFresh(state, now: now) { return true }
        guard !settings.canVerify, !state.isActive, !state.mayBeConsumedElsewhere,
              let observedAt = state.observedAt else { return false }
        return now.timeIntervalSince(observedAt) <= Self.idleFallbackFreshness
    }

    /// What the account's work costs a destination with a session window, in
    /// session percent per hour; `tier` measures a destination's margin in
    /// those units. An account without one has only its long-window rate.
    func expectedSessionBurn(of state: QuotaAccountState) -> Double {
        state.usage?.fiveHour != nil
            ? state.sessionBurnPerHour
            : state.weeklyBurnPerHour * (state.sessionPerWeekly ?? Self.defaultSessionPerWeekly)
    }

    /// Session-percentage units of work the account can still serve now.
    func headroom(_ state: QuotaAccountState, _ projection: QuotaProjection) -> Double {
        guard let weekly = projection.weekly else { return 0 }
        return Allowance.sessionRoom(sessionUsed: projection.session, weeklyUsed: weekly,
                                     sessionPerWeekly: state.sessionPerWeekly ?? Self.defaultSessionPerWeekly,
                                     sessionRoomWhenUnread: settings.sessionQuotaMode == .required ? 0 : .infinity)
    }

    func tier(
        _ state: QuotaAccountState,
        now: Date,
        expectedSessionBurn: Double = 0,
        expectedWeeklyBurn: Double = 0
    ) -> QuotaTier {
        guard !state.refusedAtLimit, state.workloadAvailable, state.credentialsUsable, !state.resetUnverified,
              let projection = projection(state, now: now),
              let weekly = projection.weekly else { return .ineligible }
        if projection.session == nil, settings.sessionQuotaMode == .required { return .ineligible }
        let session = projection.session ?? 0
        if let measured = measuredProjection(state, now: now), reachesLimit(state, measured) {
            return .exhausted
        }
        let dwellHours = settings.minimumDwell / 3600
        let sessionMargin = max(1, max(expectedSessionBurn, state.sessionBurnPerHour) * dwellHours)
            + onAccount(settings.switchCostPercent, state)
        let weeklyMargin = max(0.5, max(expectedWeeklyBurn, state.weeklyBurnPerHour) * dwellHours)
        let sessionLimit = projection.session == nil ? 100 : settings.sessionTrigger
        if session < sessionLimit - sessionMargin && weekly < settings.weeklyTrigger - weeklyMargin {
            return .belowTrigger
        }
        return .usable
    }

    /// Whether the account can take work now. A refusal at the limit counts
    /// as at the limit, though `tier` places such an account among the
    /// ineligible, so a session resumed onto it is not taken to have room.
    /// `lead` is how long before a projected limit the account counts as
    /// near it; 0 asks only whether it can serve at all. Only a reading or
    /// a refusal gives `.atLimit`; a forecast at or past a limit gives
    /// `.nearLimit` whatever the lead, so new sessions are not placed there
    /// while the sessions on it stay.
    func servingVerdict(_ state: QuotaAccountState, now: Date, lead: TimeInterval) -> ServingVerdict {
        if state.refusedAtLimit { return .atLimit }
        switch tier(state, now: now) {
        case .exhausted: return .atLimit
        case .ineligible: return .ineligible
        case .belowTrigger, .usable:
            // The sessions' own pace outranks a live reading with room: at
            // a burst's rate the room it shows can be gone before the next
            // reading arrives.
            if lead > 0, let runway = runway(state, now: now), runway < max(lead, state.runwayLead) { return .nearLimit }
            if liveReadingShowsRoom(state, now: now) { return .canServe }
            if isForecastAtLimit(state, now: now) { return .nearLimit }
            return (secondsUntilExhaustion(state, now: now) ?? .infinity) < lead ? .nearLimit : .canServe
        }
    }

    /// The account as it serves the work already running on it: its own
    /// stored credential, an unconfirmed reset and a refusal already
    /// answered by moving do not stop that work. `plan` judges the active
    /// account by it, and `AppState.moveSessionsOffLimitedAccounts` the
    /// accounts sessions were left on.
    func servingView(_ state: QuotaAccountState) -> QuotaAccountState {
        var serving = state
        serving.credentialsUsable = true
        serving.resetUnverified = false
        serving.refusedAtLimit = false
        return serving
    }

    /// Whether the active account has crossed, or will cross before the next
    /// decision, a trigger or the hard limit. A live reading with room
    /// (`liveReadingShowsRoom`) says it has not; the next one follows
    /// within seconds.
    func isTriggered(_ state: QuotaAccountState, now: Date) -> Bool {
        guard !liveReadingShowsRoom(state, now: now) else { return false }
        guard let projection = projection(state, now: now), let upper = upperProjection(state, now: now) else { return false }
        if let session = upper.session, session >= settings.sessionTrigger { return true }
        if let weekly = upper.weekly, weekly >= settings.weeklyTrigger { return true }
        return headroom(state, projection) < Self.minimumUsableHeadroom
    }

    /// The upper estimate of the account's usage at the next decision: the
    /// rate plus one deviation over the reading's age and the lookahead.
    func upperProjection(_ state: QuotaAccountState, now: Date) -> QuotaProjection? {
        guard var projection = projection(state, now: now) else { return nil }
        let ahead = Self.decisionLookahead / 3600
        let consuming = state.isActive || state.mayBeConsumedElsewhere
        let age = consuming ? projection.age / 3600 : 0
        projection.session = projection.session.map {
            $0 + state.sessionBurnStdDev * age + (state.sessionBurnPerHour + state.sessionBurnStdDev) * ahead
        }
        projection.weekly = projection.weekly.map {
            $0 + state.weeklyBurnStdDev * age + (state.weeklyBurnPerHour + state.weeklyBurnStdDev) * ahead
        }
        return projection
    }

    /// Headroom left at the next decision on the upper estimate.
    func upperHeadroom(_ state: QuotaAccountState, now: Date) -> Double? {
        upperProjection(state, now: now).map { headroom(state, $0) }
    }

    /// Latest time continuous use must begin for the remaining long-window
    /// allowance to be fully consumed before it resets, given that the
    /// 5-hour cap limits how fast that allowance can be drained.
    func latestStart(_ state: QuotaAccountState, now: Date) -> Date {
        guard let projection = projection(state, now: now),
              let weekly = projection.weekly,
              let reset = projection.weeklyReset else { return .distantFuture }
        // Without a session window to read, and none required, nothing caps
        // how fast the long window drains.
        let uncapped = projection.session == nil && settings.sessionQuotaMode != .required
        return Allowance.latestStart(weeklyUsed: weekly, resetsAt: reset,
                                     sessionPerWeekly: uncapped ? nil : state.sessionPerWeekly ?? Self.defaultSessionPerWeekly)
    }

    /// Whether `seconds` from `now` comes before the 5-hour window's reset
    /// (`reset`, nil when none is known). A session-window crossing after
    /// it never happens in that window, which starts again empty at the
    /// reset, so `secondsUntilTrigger` and `secondsUntilExhaustion` count
    /// none: `nextSwitch` would otherwise project a switch, and the pacer
    /// keep another account's room for the shared group, on a window the
    /// reset refills first.
    private func beforeSessionReset(_ seconds: TimeInterval, reset: Date?, now: Date) -> Bool {
        reset.map { now.addingTimeInterval(seconds) < $0 } ?? true
    }

    /// Seconds until the active account is expected to cross a trigger, or
    /// nil when it is not being consumed measurably. A 5-hour window counts
    /// only when it crosses before its reset (`beforeSessionReset`).
    func secondsUntilTrigger(_ state: QuotaAccountState, now: Date) -> TimeInterval? {
        guard let projection = projection(state, now: now) else { return nil }
        var times: [TimeInterval] = []
        if let session = projection.session, state.sessionBurnPerHour > 0 {
            let target = session >= settings.sessionTrigger ? 100 : settings.sessionTrigger
            let seconds = max(0, (target - session) / state.sessionBurnPerHour * 3600)
            if beforeSessionReset(seconds, reset: projection.sessionReset, now: now) { times.append(seconds) }
        }
        if let weekly = projection.weekly, state.weeklyBurnPerHour > 0 {
            let target = weekly >= settings.weeklyTrigger ? 100 : settings.weeklyTrigger
            times.append(max(0, (target - weekly) / state.weeklyBurnPerHour * 3600))
        }
        return times.min()
    }

    /// Seconds until the active account is forecast to reach a provider
    /// limit. A forecast: it can keep new sessions off the account
    /// (`servingVerdict`) and time readings, never mark it exhausted. A
    /// 5-hour window counts only when it is spent before its reset
    /// (`beforeSessionReset`).
    func secondsUntilExhaustion(_ state: QuotaAccountState, now: Date) -> TimeInterval? {
        guard let projection = projection(state, now: now) else { return nil }
        var times: [TimeInterval] = []
        let sessionRate = state.sessionBurnPerHour + state.sessionBurnStdDev
        let weeklyRate = state.weeklyBurnPerHour + state.weeklyBurnStdDev
        if let session = projection.session, state.sessionBurnPerHour > 0 {
            let seconds = max(0, (100 - session) / sessionRate * 3600)
            if beforeSessionReset(seconds, reset: projection.sessionReset, now: now) { times.append(seconds) }
        }
        if let weekly = projection.weekly, state.weeklyBurnPerHour > 0 {
            times.append(max(0, (100 - weekly) / weeklyRate * 3600))
        }
        return times.min()
    }

    /// Seconds until the account's sessions, at their pace now
    /// (`sessionsBurnPerHour`), spend the room its last reading shows,
    /// counting what they spent since that reading: the 5-hour window's
    /// room when it is spent before its reset, and the long window's, by
    /// the plan's `sessionPerWeekly`. Nil while no session runs here or no
    /// window is known. `servingVerdict` holds an account near its limit
    /// while this is shorter than the lead, and `AppState` reads an
    /// account often while it is short (`runwayWatch`).
    func runway(_ state: QuotaAccountState, now: Date) -> TimeInterval? {
        guard let windows = runwayByWindow(state, now: now) else { return nil }
        return [windows.session, windows.weekly].compactMap { $0 }.min()
    }

    /// `runway` for each window: the 5-hour window's, nil when it resets
    /// before its sessions spend it, and the weekly allowance's. Nil while
    /// no session runs here or no reading is known. Read by `runway` and
    /// `limitingWindow`.
    func runwayByWindow(_ state: QuotaAccountState, now: Date) -> (session: TimeInterval?, weekly: TimeInterval?)? {
        guard state.sessionsBurnPerHour > 0, let measured = measuredProjection(state, now: now) else { return nil }
        let spent = state.sessionsBurnPerHour * measured.age / 3600
        var session: TimeInterval?
        if let used = measured.session {
            let seconds = max(0, 100 - used - spent) / state.sessionsBurnPerHour * 3600
            if beforeSessionReset(seconds, reset: measured.sessionReset, now: now) { session = seconds }
        }
        let weekly = measured.weekly.map { used in
            let perWeekly = max(state.sessionPerWeekly ?? Self.defaultSessionPerWeekly, 0.01)
            return max(0, 100 - used - spent / perWeekly) / (state.sessionsBurnPerHour / perWeekly) * 3600
        }
        return (session, weekly)
    }

    /// A window an account runs out of (`limitingWindow`).
    enum LimitWindow: Equatable {
        /// The 5-hour window.
        case session
        /// The weekly allowance.
        case weekly
    }

    /// The window the account runs out of first: the one its sessions, at
    /// their pace now, spend first (`runwayByWindow`), else, with no session
    /// running here, the one with less room by its last reading, the weekly
    /// allowance's room counted in session percent by the plan's
    /// `sessionPerWeekly`; at a tie the weekly allowance, which resets
    /// later. Nil with no reading. Names the limit in the events that hold
    /// a session for it.
    func limitingWindow(_ state: QuotaAccountState, now: Date) -> LimitWindow? {
        func first(_ session: Double?, _ weekly: Double?) -> LimitWindow? {
            switch (session, weekly) {
            case let (session?, weekly?): weekly <= session ? .weekly : .session
            case (.some, nil): .session
            case (nil, .some): .weekly
            case (nil, nil): nil
            }
        }
        if let windows = runwayByWindow(state, now: now), let window = first(windows.session, windows.weekly) {
            return window
        }
        guard let measured = measuredProjection(state, now: now) else { return nil }
        let perWeekly = max(state.sessionPerWeekly ?? Self.defaultSessionPerWeekly, 0.01)
        return first(measured.session.map { max(0, 100 - $0) }, measured.weekly.map { max(0, 100 - $0) * perWeekly })
    }

    /// When an exhausted account can serve again: every window at its limit
    /// must have reset. Nil when the account is not exhausted or a limiting
    /// window has no known reset.
    func availableAt(_ state: QuotaAccountState, now: Date) -> Date? {
        var limitState = state
        if state.isActive {
            limitState.credentialsUsable = true
            limitState.resetUnverified = false
        }
        guard state.credentialsUsable || state.isActive,
              tier(limitState, now: now) == .exhausted,
              let projection = measuredProjection(state, now: now) else { return nil }
        var limiting: [Date?] = []
        if let session = projection.session, session >= 100 - Self.minimumUsableHeadroom {
            limiting.append(projection.sessionReset)
        }
        if let weekly = projection.weekly, weekly >= 100 - Self.minimumUsableHeadroom {
            limiting.append(projection.weeklyReset)
        }
        guard !limiting.isEmpty, limiting.allSatisfy({ $0 != nil }) else { return nil }
        return limiting.compactMap { $0 }.max()
    }

    /// When the active account, which `plan` holds at its limit, can serve
    /// again. It is held by the same test `plan` applies: its last reading
    /// within the in-flight reserve of a limit, or a refusal at the limit.
    /// The windows within that margin must reset; with none, as after a
    /// refusal, the fuller window. `availableAt` alone counts only windows at
    /// 99%, so an account held at 98% would have no reset and an account
    /// resetting days later would be waited on instead.
    func heldAvailableAt(_ state: QuotaAccountState, now: Date) -> Date? {
        guard let measured = measuredProjection(state, now: now) else { return nil }
        let margin = onAccount(settings.inFlightReservePercent, state) + Self.minimumUsableHeadroom
        var limiting: [Date?] = []
        if let session = measured.session, session >= 100 - margin { limiting.append(measured.sessionReset) }
        if let weekly = measured.weekly, weekly >= 100 - margin { limiting.append(measured.weeklyReset) }
        if limiting.isEmpty {
            limiting.append((measured.session ?? -1) >= (measured.weekly ?? -1) ? measured.sessionReset : measured.weeklyReset)
        }
        guard limiting.allSatisfy({ $0 != nil }) else { return nil }
        return limiting.compactMap { $0 }.max()
    }

    // MARK: - Planning

    func plan(
        current: QuotaAccountState,
        ladder: [QuotaAccountState],
        recoveredIDs: Set<UUID> = [],
        lastSwitch: Date?,
        now: Date = Date()
    ) -> FailoverPlan {
        let others = rotation(ladder: ladder, currentID: current.id)
        func tierOf(_ state: QuotaAccountState) -> QuotaTier {
            let burn = expectedBurn(movingFrom: current, to: state)
            return tier(state, now: now, expectedSessionBurn: burn.session, expectedWeeklyBurn: burn.weekly)
        }

        if current.workloadAvailable, projection(current, now: now) == nil {
            return .stay(.healthy)
        }
        let serving = servingView(current)
        let currentTier = current.workloadAvailable ? tier(serving, now: now) : .exhausted
        // Only a reading or a refusal holds the account at its limit; a
        // forecast reaching it crosses a trigger (`isTriggered`), which
        // moves work only to an account below its thresholds and never
        // starts an exhausted move or a wait for a reset.
        let atLimit = currentTier == .exhausted || current.refusedAtLimit
            || isMeasuredAtLimit(serving, now: now, reserve: onAccount(settings.inFlightReservePercent, serving))
        let forced = !current.workloadAvailable || atLimit || isTriggered(current, now: now)
        guard forced else {
            return balancePlan(current: current, others: others, lastSwitch: lastSwitch, now: now)
        }
        let reason: FailoverPlan.SwitchReason = !current.workloadAvailable
            ? .workloadUnavailable
            : (atLimit ? .exhausted : .threshold)

        if !atLimit, shouldHoldForImminentReset(current, now: now) {
            return .stay(.holdingForImminentReset)
        }
        if current.workloadAvailable, let until = settings.sharedSignInWaitsUntil,
           until.addingTimeInterval(AppState.accountHoldGrace) > now {
            return .stay(.waitingForResetWithCache)
        }

        let belowTrigger = others.filter { tierOf($0) == .belowTrigger && carries($0, from: current, at: now) }
        switch readiness(of: ordered(belowTrigger, recovered: recoveredIDs, now: now), now: now) {
        case .ready(let id): return .switchTo(id, reason)
        case .needsVerification(let id): return .verify([id])
        case .none: break
        }

        if !atLimit {
            return .stay(.drainingToLimit)
        }

        let usable = others.filter { tierOf($0) == .usable && carries($0, from: current, at: now) }.sorted { lhs, rhs in
            guard let l = projection(lhs, now: now), let r = projection(rhs, now: now) else { return false }
            return tokenRoom(lhs, l) > tokenRoom(rhs, r)
        }
        switch readiness(of: usable, now: now) {
        case .ready(let id): return .switchTo(id, reason)
        case .needsVerification(let id): return .verify([id])
        case .none: break
        }

        // Accounts that may have capacity but cannot be confirmed now are
        // read before anything else happens; they are never switched to or
        // waited on unread. One whose reading leaves too little room to
        // carry the work is not read for it: `nextSwitch` takes an account
        // `plan` would read as the one it switches to.
        let unconfirmed = others.filter { state in
            let tier = tierOf(state)
            if tier == .belowTrigger || tier == .usable {
                return !canSwitchWithoutReading(state, now: now) && carries(state, from: current, at: now)
            }
            return state.resetUnverified && state.credentialsUsable && state.workloadAvailable
        }
        if !unconfirmed.isEmpty { return .verify(unconfirmed.map(\.id)) }

        // Every allowance is exhausted: extra usage, when allowed, before
        // waiting. The active account first, so no switch is spent on it.
        if settings.allowExtraUsage {
            if current.extraUsageAvailable, current.credentialsUsable { return .stay(.usingExtraUsage) }
            if let paid = others.first(where: { $0.extraUsageAvailable && $0.credentialsUsable && $0.workloadAvailable }) {
                return .switchTo(paid.id, .exhausted)
            }
        }

        // The active account is waited on by the test that holds it.
        let currentReset = heldAvailableAt(serving, now: now).map { (current.id, $0) }
        let resets = [currentReset].compactMap { $0 } + others.compactMap { state -> (UUID, Date)? in
            availableAt(state, now: now).map { (state.id, $0) }
        }
        if let earliest = resets.min(by: { $0.1 < $1.1 }) {
            return .waitForReset(earliest.0, earliest.1)
        }
        return .noCapacity
    }

    private func balancePlan(
        current: QuotaAccountState,
        others: [QuotaAccountState],
        lastSwitch: Date?,
        now: Date
    ) -> FailoverPlan {
        guard settings.balancing, settings.canSwitchProactively else { return .stay(.healthy) }
        if let lastSwitch, now.timeIntervalSince(lastSwitch) < settings.minimumDwell {
            return .stay(.dwell)
        }
        let floor = settings.balanceMovingTokensPerHour
        let candidates = others.filter {
            let burn = expectedBurn(movingFrom: current, to: $0, floor: floor)
            // A balance switch moves the whole shared group, as failover
            // does: a small remainder is left to the slot sessions and new
            // sessions the pool sizes to it.
            return tier($0, now: now, expectedSessionBurn: burn.session, expectedWeeklyBurn: burn.weekly) == .belowTrigger
                && carries($0, from: current, at: now, floor: floor)
        }.sorted { latestStart($0, now: now) < latestStart($1, now: now) }
        guard let best = candidates.first else { return .stay(.healthy) }
        let advantage = latestStart(current, now: now).timeIntervalSince(latestStart(best, now: now)) / 3600
        if let demand = settings.demand {
            // With a demand forecast, the coming week decides: the switch must
            // serve more work, or leave less allowance to expire, than staying,
            // by more than the switch itself costs.
            let accounts = ([current] + others).compactMap { simulatorAccount($0, now: now) }
            let simulator = QuotaSimulator()
            let stay = simulator.run(accounts: accounts, strategy: .preferring([current.id]), demand: demand, start: now)
            let move = simulator.run(accounts: accounts, strategy: .preferring([best.id]), demand: demand, start: now)
            let k = current.sessionPerWeekly ?? Self.defaultSessionPerWeekly
            let gain = (stay.unmet + stay.expired) - (move.unmet + move.expired)
            guard gain > max(0.5, settings.switchCostPercent / k) else { return .stay(.healthy) }
        } else {
            guard advantage.isFinite, advantage >= settings.balancingAdvantageHours else { return .stay(.healthy) }
        }
        guard canSwitchWithoutReading(best, now: now) else {
            return settings.canVerify ? .verify([best.id]) : .stay(.healthy)
        }
        return .switchTo(best.id, .balance(advantageHours: advantage))
    }

    /// The account as the simulator models it, from its projected usage,
    /// with demand, which is counted at `Settings.referenceRatio`, scaled to
    /// its own size (`QuotaSimulator.Account.scale`).
    func simulatorAccount(_ state: QuotaAccountState, now: Date) -> QuotaSimulator.Account? {
        guard let projection = projection(state, now: now), let weekly = projection.weekly else { return nil }
        return QuotaSimulator.Account(
            id: state.id,
            session: projection.session ?? 0,
            sessionReset: projection.sessionReset,
            weekly: weekly,
            weeklyReset: projection.weeklyReset,
            sessionPerWeekly: state.sessionPerWeekly ?? Self.defaultSessionPerWeekly,
            usable: state.credentialsUsable && state.workloadAvailable,
            hasSessionWindow: state.usage?.fiveHour != nil,
            scale: onAccount(1, state)
        )
    }

    private func shouldHoldForImminentReset(_ state: QuotaAccountState, now: Date) -> Bool {
        guard settings.waitForImminentReset, let projection = projection(state, now: now) else { return false }
        var breachedResets: [Date?] = []
        if let session = projection.session, session >= settings.sessionTrigger {
            breachedResets.append(projection.sessionReset)
        }
        if let weekly = projection.weekly, weekly >= settings.weeklyTrigger {
            breachedResets.append(projection.weeklyReset)
        }
        guard !breachedResets.isEmpty else { return false }
        return breachedResets.allSatisfy { reset in
            guard let reset else { return false }
            let remaining = reset.timeIntervalSince(now)
            // The active account must be able to keep serving until then.
            let exhaustion = secondsUntilExhaustion(state, now: now) ?? .infinity
            return remaining > 0 && remaining <= settings.resetGrace && exhaustion > remaining
        }
    }

    /// Candidates after the active account in ladder order, wrapping when looping.
    private func rotation(ladder: [QuotaAccountState], currentID: UUID) -> [QuotaAccountState] {
        guard let index = ladder.firstIndex(where: { $0.id == currentID }) else {
            return ladder.filter { $0.id != currentID }
        }
        let after = Array(ladder.dropFirst(index + 1))
        return settings.loops ? after + Array(ladder.prefix(index)) : after
    }

    private func ordered(
        _ states: [QuotaAccountState],
        recovered: Set<UUID>,
        now: Date
    ) -> [QuotaAccountState] {
        if settings.balancing {
            return states.enumerated().sorted { lhs, rhs in
                let l = latestStart(lhs.element, now: now), r = latestStart(rhs.element, now: now)
                return l == r ? lhs.offset < rhs.offset : l < r
            }.map(\.element)
        }
        if settings.preferMostCapacity {
            return states.sorted { lhs, rhs in
                guard let l = projection(lhs, now: now), let r = projection(rhs, now: now) else { return false }
                return tokenRoom(lhs, l) > tokenRoom(rhs, r)
            }
        }
        guard settings.resetAware, !recovered.isEmpty else { return states }
        return states.filter { recovered.contains($0.id) } + states.filter { !recovered.contains($0.id) }
    }

    private enum Readiness { case ready(UUID), needsVerification(UUID), none }

    /// The most preferred candidate that can be switched to now. A preferred
    /// candidate whose reading may be out of date is verified first rather
    /// than skipped, so the ladder is honoured with current data.
    private func readiness(of states: [QuotaAccountState], now: Date) -> Readiness {
        for state in states {
            if isFresh(state, now: now) { return .ready(state.id) }
            if settings.canVerify { return .needsVerification(state.id) }
            if canSwitchWithoutReading(state, now: now) { return .ready(state.id) }
        }
        return .none
    }

    /// Whether some other account could take the workload now or after one
    /// reading, following the same rotation, tiers and `carries` as `plan`.
    func hasFallback(current: QuotaAccountState, ladder: [QuotaAccountState], now: Date) -> Bool {
        rotation(ladder: ladder, currentID: current.id).contains { state in
            let burn = expectedBurn(movingFrom: current, to: state)
            let tier = tier(state, now: now, expectedSessionBurn: burn.session, expectedWeeklyBurn: burn.weekly)
            guard tier <= .usable, settings.canVerify || canSwitchWithoutReading(state, now: now) else { return false }
            return carries(state, from: current, at: now)
        }
    }

    /// What a destination is expected to carry per hour once `current`'s
    /// work moves to it, in session and long-window percent: the work that
    /// moves, the active account's burn less its slot sessions
    /// (`QuotaAccountState.stayingSessionBurnPerHour`), beside the
    /// destination's own slot sessions, which stay. `tier` takes the larger
    /// of this and the destination's measured burn, which already holds its
    /// slot sessions once its readings show them. `floor`, in weighted
    /// tokens per hour, is the least the moving work counts as
    /// (`Settings.balanceMovingTokensPerHour`), at the destination's cost.
    func expectedBurn(movingFrom current: QuotaAccountState,
                      to destination: QuotaAccountState, floor: Double = 0) -> (session: Double, weekly: Double) {
        let k = current.sessionPerWeekly ?? Self.defaultSessionPerWeekly
        let destinationK = destination.sessionPerWeekly ?? Self.defaultSessionPerWeekly
        let least = Allowance.percent(millions: max(0, floor) / 1_000_000, percentPerMillion: destination.percentPerMillion)
        // The moving work is `current`'s percent; the destination counts
        // the same tokens at its own size.
        let session = max(least, converted(max(0, expectedSessionBurn(of: current) - current.stayingSessionBurnPerHour),
                                           from: current, to: destination))
            + destination.stayingSessionBurnPerHour
        let weekly = max(least, converted(max(0, current.weeklyBurnPerHour - current.stayingSessionBurnPerHour / k) * k,
                                          from: current, to: destination)) / destinationK
            + destination.stayingSessionBurnPerHour / destinationK
        return (session, weekly)
    }

    /// `percent` of `from`'s session window as the same work in `to`'s:
    /// through tokens, by each account's own token cost
    /// (`QuotaAccountState.percentPerMillion`). A percent of a plan a
    /// twentieth the size is a twentieth of the work. Read by
    /// `expectedBurn` and `carriedBurn`.
    func converted(_ percent: Double, from: QuotaAccountState, to: QuotaAccountState) -> Double {
        Allowance.converted(percent, from: from.percentPerMillion, to: to.percentPerMillion)
    }

    /// `percent`, counted at `Settings.referenceRatio`, as `state`'s session
    /// percent: the switch's cost and the in-flight reserve where they land.
    func onAccount(_ percent: Double, _ state: QuotaAccountState) -> Double {
        Allowance.converted(percent, from: settings.referenceRatio, to: state.percentPerMillion)
    }

    /// Million weighted tokens the account can still serve now: its
    /// `headroom` through its own token cost. Room is compared across
    /// accounts by this, since 50% of a small plan can be less work than
    /// 10% of a large one. Read by `plan`'s ordering of destinations and by
    /// `nextSwitch`'s preference for the account it projected.
    func tokenRoom(_ state: QuotaAccountState, _ projection: QuotaProjection) -> Double {
        Allowance.millions(headroom(state, projection), percentPerMillion: state.percentPerMillion)
    }

    /// The account `plan` would make active next, and when.
    struct NextSwitch: Equatable {
        var account: UUID
        var at: Date
    }

    /// When the active account is projected to be switched away from, and
    /// to which account, by `plan` itself: asked as of the moment its
    /// burn carries it across a trigger, and failing a switch then, as of
    /// the moment it reaches its limit, when a reading or a refusal will
    /// show the limit. A destination `plan` would read first
    /// (`FailoverPlan.verify`) is taken as the one it switches to. Nil when
    /// the active account is not projected to reach either, or `plan`
    /// would keep it or wait for a reset then. Read by `SessionPacer`'s
    /// shared group, which moves with the active account.
    ///
    /// `plan` switches only to a destination that `carries` the moving
    /// work, so the account projected here is the one the switch picks.
    /// `keeping`, the account projected last time
    /// (`AppState.sharedGroupDestination`), stays the projection while
    /// `plan` would still switch to it, unless the account `plan` prefers
    /// now has `projectionPreference` times its headroom: the pacer keeps
    /// room on the projected account, and moving that room between two
    /// accounts each cycle moves the slot sessions placed around it.
    func nextSwitch(current: QuotaAccountState, ladder: [QuotaAccountState],
                    recoveredIDs: Set<UUID> = [], keeping previous: UUID? = nil, now: Date) -> NextSwitch? {
        let withCurrent = ladder.contains { $0.id == current.id } ? ladder : [current] + ladder
        func destination(_ plan: FailoverPlan, from current: QuotaAccountState) -> UUID? {
            switch plan {
            case .switchTo(let id, _): id == current.id ? nil : id
            case .verify(let ids): ids.first { $0 != current.id }
            case .stay, .waitForReset, .noCapacity: nil
            }
        }
        // The account `plan` switches to at `at`, or nil.
        func carrier(_ current: QuotaAccountState, among ladder: [QuotaAccountState], at: Date) -> QuotaAccountState? {
            destination(plan(current: current, ladder: ladder, recoveredIDs: recoveredIDs, lastSwitch: nil, now: at),
                        from: current).flatMap { id in ladder.first { $0.id == id } }
        }
        func choice(_ current: QuotaAccountState, among ladder: [QuotaAccountState], at: Date) -> NextSwitch? {
            guard let chosen = carrier(current, among: ladder, at: at) else { return nil }
            if let previous, previous != chosen.id, previous != current.id,
               let kept = ladder.first(where: { $0.id == previous }),
               carrier(current, among: ladder.filter { $0.id == current.id || $0.id == previous }, at: at)?.id == previous,
               let keptRoom = projection(kept, now: at).map({ tokenRoom(kept, $0) }),
               let chosenRoom = projection(chosen, now: at).map({ tokenRoom(chosen, $0) }),
               chosenRoom < keptRoom * Self.projectionPreference {
                return NextSwitch(account: previous, at: at)
            }
            return NextSwitch(account: chosen.id, at: at)
        }
        if let toTrigger = secondsUntilTrigger(current, now: now),
           let next = choice(current, among: withCurrent, at: now.addingTimeInterval(toTrigger)) {
            return next
        }
        guard let toLimit = secondsUntilExhaustion(current, now: now) else { return nil }
        var limited = current
        limited.refusedAtLimit = true
        let ladderAtLimit = withCurrent.map { $0.id == current.id ? limited : $0 }
        return choice(limited, among: ladderAtLimit, at: now.addingTimeInterval(toLimit))
    }

    /// How long a switch destination must be able to carry the work that
    /// moves to it (`carries`): the lifetime of the prompt caches the move
    /// writes there (`SessionPacer.defaultCacheLifetime`). The moving
    /// sessions would leave an account with less within that time and
    /// write their contexts a second time, for the little it served.
    static let projectedCarry: TimeInterval = 60 * 60
    /// The share of an unused window a destination must have room for
    /// when the rate would spend a whole window within `projectedCarry`:
    /// no account carries such a burst for the horizon, and the work must
    /// still move to the one that carries it longest.
    static let burstCarryShare = 0.5
    /// How much more headroom the account `plan` prefers must have before
    /// `nextSwitch` drops the account it projected last time for it.
    static let projectionPreference = 2.0

    /// What a destination carries per hour once `current`'s work moves to
    /// it, on the upper estimate, in session and long-window percent: the
    /// moving work beside its own slot sessions (`expectedBurn`) plus the
    /// deviation of `current`'s rate, or the destination's own measured
    /// rate plus its deviation when that is larger. A rate is converted
    /// from the long window, by the plan's ratio, for an account without a
    /// session window, whose session rate is never learned. `current`'s
    /// rate and deviation are converted to the destination's size
    /// (`converted`). `floor` as in `expectedBurn`.
    func carriedBurn(from current: QuotaAccountState, to destination: QuotaAccountState,
                     floor: Double = 0) -> (session: Double, weekly: Double) {
        func sessionDeviation(_ state: QuotaAccountState) -> Double {
            state.usage?.fiveHour != nil
                ? state.sessionBurnStdDev
                : state.weeklyBurnStdDev * (state.sessionPerWeekly ?? Self.defaultSessionPerWeekly)
        }
        let moving = expectedBurn(movingFrom: current, to: destination, floor: floor)
        let k = current.sessionPerWeekly ?? Self.defaultSessionPerWeekly
        let destinationK = destination.sessionPerWeekly ?? Self.defaultSessionPerWeekly
        let weeklyDeviation = converted(current.weeklyBurnStdDev * k, from: current, to: destination) / destinationK
        return (
            max(moving.session + converted(sessionDeviation(current), from: current, to: destination),
                expectedSessionBurn(of: destination) + sessionDeviation(destination)),
            max(moving.weekly + weeklyDeviation, destination.weeklyBurnPerHour + destination.weeklyBurnStdDev)
        )
    }

    /// Whether `destination` has the room, at `date`, to carry the work
    /// moving from `current` on each window it has, for `projectedCarry` or
    /// until that window resets when sooner: the 5-hour window at the session rate of `carriedBurn`, the long
    /// window at its long-window rate (in session percent by the plan's
    /// ratio), each beside the in-flight reserve and the switch's cost, and
    /// never less than `destinationMinimum`. The one rule for a switch
    /// destination: `plan` switches only to such an account, failing over,
    /// crossing a threshold or balancing, so `nextSwitch`, which asks
    /// `plan`, projects the account the switch will pick. `tier`'s dwell
    /// margin, in long-window percent over the dwell, passes an account a
    /// few percent from its limit, which the moving work spends in minutes.
    /// `floor`, in weighted tokens per hour, is the least the moving work
    /// counts as (`Settings.balanceMovingTokensPerHour`); a balance switch
    /// and the accounts `AppState.remainderSpending` offers pass it.
    func carries(_ destination: QuotaAccountState, from current: QuotaAccountState, at date: Date,
                 floor: Double = 0) -> Bool {
        guard let projection = projection(destination, now: date), let weekly = projection.weekly else { return false }
        let burn = carriedBurn(from: current, to: destination, floor: floor)
        // A window that resets within the horizon needs room only until
        // then, and one no account could carry the rate for that long only
        // for as long as `burstCarryShare` of an unused window would. The
        // burst is judged at the size of the account the work comes from
        // (`sourceRate`): a rate that would spend a whole window only
        // because the destination's plan is small is no burst, and a
        // larger account carries it.
        func hours(until reset: Date?, sourceRate: Double) -> Double {
            let untilReset = reset.map { max(0, $0.timeIntervalSince(date)) } ?? Self.projectedCarry
            let burst = sourceRate > 0 ? Self.burstCarryShare * 100 / sourceRate * 3600 : Self.projectedCarry
            return min(Self.projectedCarry, untilReset, burst) / 3600
        }
        let fixed = onAccount(settings.inFlightReservePercent + settings.switchCostPercent, destination)
        let k = destination.sessionPerWeekly ?? Self.defaultSessionPerWeekly
        let currentK = current.sessionPerWeekly ?? Self.defaultSessionPerWeekly
        if let session = projection.session,
           100 - session < fixed + burn.session * hours(until: projection.sessionReset,
                                                       sourceRate: converted(burn.session, from: destination, to: current)) {
            return false
        }
        let weeklyNeed = burn.weekly * hours(until: projection.weeklyReset,
                                             sourceRate: converted(burn.weekly * k, from: destination, to: current) / currentK)
        guard (100 - weekly) * k >= fixed + weeklyNeed * k else { return false }
        return headroom(destination, projection) >= destinationMinimum(current: current, destination: destination)
    }

    /// Headroom a destination needs to take work from an account at its
    /// limit, whatever it carries for longer (`carries`): the in-flight
    /// reserve, the cost of the move, and `minimumDestinationMinutes` of
    /// `carriedBurn`'s session rate. The larger of the moving work and the
    /// destination's own measured rate counts, since the current account's
    /// rate falls to nothing while its sessions are paused, and a sliver
    /// that looked enough then is used up as soon as they resume on it,
    /// which switches straight back.
    func destinationMinimum(current: QuotaAccountState, destination: QuotaAccountState) -> Double {
        let burn = carriedBurn(from: current, to: destination).session
        return max(
            Self.minimumUsableHeadroom,
            onAccount(settings.inFlightReservePercent + settings.switchCostPercent, destination)
                + burn * settings.minimumDestinationMinutes / 60
        )
    }

    /// How old the active account's reading may grow before it is read again:
    /// half the time it is projected to take to cross its next trigger, or
    /// its limit once a trigger is crossed, between 30 seconds and 5 minutes.
    /// Consumed by `AppState.activeReadingIsDue`.
    func readingInterval(_ state: QuotaAccountState, now: Date) -> TimeInterval {
        let horizon: TimeInterval
        if isTriggered(state, now: now) {
            horizon = secondsUntilExhaustion(state, now: now) ?? 300
        } else {
            horizon = secondsUntilTrigger(state, now: now) ?? 600
        }
        return max(30, min(300, horizon / 2))
    }

    /// When the active account's next reading is useful. An account held at a
    /// limit only changes at its reset, so it is read just after that reset
    /// with a sparse sentinel read in between.
    func nextUsefulReading(_ state: QuotaAccountState, now: Date) -> Date? {
        var serving = state
        serving.credentialsUsable = true
        serving.resetUnverified = false
        guard tier(serving, now: now) == .exhausted, let available = availableAt(serving, now: now) else { return nil }
        return min(available.addingTimeInterval(5), now.addingTimeInterval(15 * 60))
    }
}

extension FailoverPlanner {
    /// The period `isSwitchLoop` counts switches over.
    static let switchLoopWindow: TimeInterval = 15 * 60

    /// Whether failover leaving one account at `times` is a loop: three
    /// switches away within `switchLoopWindow` mean the account keeps being
    /// made active again, so another switch would only repeat it.
    static func isSwitchLoop(_ times: [Date], now: Date) -> Bool {
        times.filter { now.timeIntervalSince($0) < switchLoopWindow }.count >= 3
    }
}
