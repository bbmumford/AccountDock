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
        case dwell
        /// Every allowance is exhausted; the account serves on extra usage.
        case usingExtraUsage
    }

    enum SwitchReason: Equatable {
        case threshold
        case exhausted
        case balance(advantageHours: Double)
        case workloadUnavailable
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
///    for the expected burn over the minimum dwell. Accounts that may be
///    consumed elsewhere must have been read recently.
/// 2. Once the active account crosses a trigger it moves to such a
///    destination. When none exists it keeps serving up to the provider's
///    100% limit, because moving to an account that is merely less full
///    than its trigger wastes switches without adding capacity.
/// 3. At 100% it moves to the usable account with the most headroom.
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
    static let sessionWindow: TimeInterval = 5 * 60 * 60
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
        let session: Double
        if let value = projection.session {
            session = 100 - value
        } else {
            session = settings.sessionQuotaMode == .required ? 0 : .infinity
        }
        guard let weekly = projection.weekly else { return 0 }
        let k = state.sessionPerWeekly ?? Self.defaultSessionPerWeekly
        return max(0, min(session, (100 - weekly) * k))
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
        let sessionMargin = max(1, max(expectedSessionBurn, state.sessionBurnPerHour) * dwellHours) + settings.switchCostPercent
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
        let k = state.sessionPerWeekly ?? Self.defaultSessionPerWeekly
        let maximumWeeklyPerHour = projection.session == nil && settings.sessionQuotaMode != .required
            ? Double.infinity
            : (100 / k) / (Self.sessionWindow / 3600)
        let hoursNeeded = (100 - weekly) / maximumWeeklyPerHour
        return reset.addingTimeInterval(-hoursNeeded * 3600)
    }

    /// Seconds until the active account is expected to cross a trigger, or
    /// nil when it is not being consumed measurably.
    func secondsUntilTrigger(_ state: QuotaAccountState, now: Date) -> TimeInterval? {
        guard let projection = projection(state, now: now) else { return nil }
        var times: [TimeInterval] = []
        if let session = projection.session, state.sessionBurnPerHour > 0 {
            let target = session >= settings.sessionTrigger ? 100 : settings.sessionTrigger
            times.append(max(0, (target - session) / state.sessionBurnPerHour * 3600))
        }
        if let weekly = projection.weekly, state.weeklyBurnPerHour > 0 {
            let target = weekly >= settings.weeklyTrigger ? 100 : settings.weeklyTrigger
            times.append(max(0, (target - weekly) / state.weeklyBurnPerHour * 3600))
        }
        return times.min()
    }

    /// Seconds until the active account is forecast to reach a provider
    /// limit. A forecast: it can keep new sessions off the account
    /// (`servingVerdict`) and time readings, never mark it exhausted.
    func secondsUntilExhaustion(_ state: QuotaAccountState, now: Date) -> TimeInterval? {
        guard let projection = projection(state, now: now) else { return nil }
        var times: [TimeInterval] = []
        let sessionRate = state.sessionBurnPerHour + state.sessionBurnStdDev
        let weeklyRate = state.weeklyBurnPerHour + state.weeklyBurnStdDev
        if let session = projection.session, state.sessionBurnPerHour > 0 {
            times.append(max(0, (100 - session) / sessionRate * 3600))
        }
        if let weekly = projection.weekly, state.weeklyBurnPerHour > 0 {
            times.append(max(0, (100 - weekly) / weeklyRate * 3600))
        }
        return times.min()
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
        let margin = settings.inFlightReservePercent + Self.minimumUsableHeadroom
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
        let burnS = expectedSessionBurn(of: current)
        let burnW = current.weeklyBurnPerHour
        func tierOf(_ state: QuotaAccountState) -> QuotaTier {
            tier(state, now: now, expectedSessionBurn: burnS, expectedWeeklyBurn: burnW)
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
            || isMeasuredAtLimit(serving, now: now, reserve: settings.inFlightReservePercent)
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

        let belowTrigger = others.filter { tierOf($0) == .belowTrigger }
        switch readiness(of: ordered(belowTrigger, recovered: recoveredIDs, now: now), now: now) {
        case .ready(let id): return .switchTo(id, reason)
        case .needsVerification(let id): return .verify([id])
        case .none: break
        }

        if !atLimit {
            return .stay(.drainingToLimit)
        }

        let usable = others.filter { state in
            guard tierOf(state) == .usable, let projection = projection(state, now: now) else { return false }
            return headroom(state, projection) >= destinationMinimum(current: current, destination: state)
        }.sorted { lhs, rhs in
            guard let l = projection(lhs, now: now), let r = projection(rhs, now: now) else { return false }
            return headroom(lhs, l) > headroom(rhs, r)
        }
        switch readiness(of: usable, now: now) {
        case .ready(let id): return .switchTo(id, reason)
        case .needsVerification(let id): return .verify([id])
        case .none: break
        }

        // Accounts that may have capacity but cannot be confirmed now are
        // read before anything else happens; they are never switched to or
        // waited on unread.
        let unconfirmed = others.filter { state in
            let tier = tierOf(state)
            if tier == .belowTrigger || tier == .usable { return !canSwitchWithoutReading(state, now: now) }
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
        let burnS = expectedSessionBurn(of: current)
        let burnW = current.weeklyBurnPerHour
        let candidates = others.filter {
            tier($0, now: now, expectedSessionBurn: burnS, expectedWeeklyBurn: burnW) == .belowTrigger
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

    /// The account as the simulator models it, from its projected usage.
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
            hasSessionWindow: state.usage?.fiveHour != nil
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
                return headroom(lhs, l) > headroom(rhs, r)
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
    /// reading, following the same rotation and tiers as `plan`.
    func hasFallback(current: QuotaAccountState, ladder: [QuotaAccountState], now: Date) -> Bool {
        rotation(ladder: ladder, currentID: current.id).contains { state in
            let tier = tier(
                state, now: now,
                expectedSessionBurn: current.sessionBurnPerHour,
                expectedWeeklyBurn: current.weeklyBurnPerHour
            )
            guard tier <= .usable, settings.canVerify || canSwitchWithoutReading(state, now: now) else { return false }
            if tier == .belowTrigger { return true }
            guard let projection = projection(state, now: now) else { return false }
            return headroom(state, projection) >= destinationMinimum(current: current, destination: state)
        }
    }

    /// Headroom a usable account needs to take work from an account at its
    /// limit: the in-flight reserve, the cost of the move, and
    /// `minimumDestinationMinutes` of burn on the upper estimate. The burn is
    /// the larger of the account being left and the destination's own, since
    /// the current account's rate falls to nothing while its sessions are
    /// paused, and a sliver that looked enough then was used up as soon as
    /// they resumed on it, which switched straight back.
    func destinationMinimum(current: QuotaAccountState, destination: QuotaAccountState) -> Double {
        let burn = max(current.sessionBurnPerHour + current.sessionBurnStdDev,
                       destination.sessionBurnPerHour + destination.sessionBurnStdDev)
        return max(
            Self.minimumUsableHeadroom,
            settings.inFlightReservePercent + settings.switchCostPercent + burn * settings.minimumDestinationMinutes / 60
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
