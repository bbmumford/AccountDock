import Foundation

/// Sessions pinned to one subscription, by session ID, so a resumed session
/// with the same ID is pinned too. Nothing automatic moves a pinned session:
/// `AppState.serveSessionSlots` keeps its slot on the pinned account,
/// `SessionPacer` counts it as fixed load there, and neither
/// `applyModelFallbacks` nor rebalancing touches it. Only a session in a
/// one-session slot can be pinned; one on the shared sign-in moves with the
/// active account. Kept in `UserDefaults` under `defaultsKey` by
/// `AppState.sessionPins`.
struct SessionPins: Codable, Equatable {
    struct Pin: Codable, Equatable {
        var account: UUID
        /// The provider's raw value.
        var provider: String
        var pinnedAt: Date
    }

    /// Pins by session ID.
    var sessions: [String: Pin] = [:]
    /// Pins of slots claimed for a session that has not started yet, as one
    /// opened from a tile's session button (`AppState.sessionLaunch`), by
    /// the slot's path; `adopt` pins the session once it reads its slot.
    var slots: [String: Pin] = [:]

    static let defaultsKey = "app.accountdock.failover.pins"
    /// A pin whose session has no record yet is kept this long, as its
    /// first record may be written after it was pinned.
    static let recordGrace: TimeInterval = 10 * 60
    /// A slot pin is kept as long as `AppState.requestedClaimGrace` keeps
    /// the slot: its command may be run some minutes after it was made.
    static let slotGrace: TimeInterval = 30 * 60

    func account(of session: String?) -> UUID? {
        session.flatMap { sessions[$0]?.account }
    }

    func isPinned(_ session: String?) -> Bool { account(of: session) != nil }

    /// Pinned sessions of one provider.
    func pinned(_ provider: AIProviderType) -> [String: Pin] {
        sessions.filter { $0.value.provider == provider.rawValue }
    }

    enum Outcome: Equatable {
        case pinned(UUID)
        case alreadyPinned(UUID)
        /// The session reads no one-session slot: it shares the sign-in.
        case notInSlot
        case unpinned(UUID)
        case notPinned
    }

    /// Pins `session` to `slotAccount`, the account its one-session slot
    /// serves; nil when it reads none.
    mutating func pin(_ session: String, slotAccount: UUID?, provider: AIProviderType, at now: Date) -> Outcome {
        guard let slotAccount else { return .notInSlot }
        if let existing = sessions[session], existing.account == slotAccount { return .alreadyPinned(slotAccount) }
        sessions[session] = Pin(account: slotAccount, provider: provider.rawValue, pinnedAt: now)
        return .pinned(slotAccount)
    }

    mutating func unpin(_ session: String) -> Outcome {
        guard let removed = sessions.removeValue(forKey: session) else { return .notPinned }
        return .unpinned(removed.account)
    }

    /// Pins the slot at `path` for the session that will read it.
    mutating func pinSlot(_ path: String, account: UUID, provider: AIProviderType, at now: Date) {
        slots[path] = Pin(account: account, provider: provider.rawValue, pinnedAt: now)
    }

    /// Moves each slot pin to the session now reading its slot
    /// (`sessionsBySlot`, slot path to session ID). Returns the sessions
    /// pinned.
    mutating func adopt(sessionsBySlot: [String: String]) -> [String] {
        var adopted: [String] = []
        for (path, session) in sessionsBySlot.sorted(by: { $0.key < $1.key }) {
            guard let pin = slots.removeValue(forKey: path) else { continue }
            if sessions[session] == nil { adopted.append(session) }
            sessions[session] = pin
        }
        return adopted
    }

    /// Drops the pins of `provider`'s sessions that no longer have a record
    /// (`recorded`, the session IDs `AgentSessions.records` lists: ended
    /// long ago and archived, or removed), after `recordGrace`, and slot
    /// pins past `slotGrace`. Returns the sessions unpinned.
    mutating func prune(_ provider: AIProviderType, recorded: Set<String>, now: Date) -> [String] {
        let gone = sessions.filter { session, pin in
            pin.provider == provider.rawValue && !recorded.contains(session)
                && now.timeIntervalSince(pin.pinnedAt) > Self.recordGrace
        }.keys.sorted()
        for session in gone { sessions[session] = nil }
        slots = slots.filter { $0.value.provider != provider.rawValue || now.timeIntervalSince($0.value.pinnedAt) <= Self.slotGrace }
        return gone
    }

    static func load(_ defaults: UserDefaults = .standard) -> SessionPins {
        guard let data = defaults.data(forKey: defaultsKey),
              let pins = try? JSONDecoder().decode(SessionPins.self, from: data) else { return SessionPins() }
        return pins
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Whether a session opened from a tile's session button is pinned to
    /// that subscription: by default, unless "Keep here" was unchecked in
    /// the button's menu or the Option key was held when choosing.
    static func pinsOpenedSession(keepHere: Bool, optionHeld: Bool) -> Bool {
        keepHere && !optionHeld
    }

    /// Of the model fallbacks waiting for their sessions to go idle
    /// (`AppState.pendingModelFallbacks`), those `applyModelFallbacks` may
    /// make: a pinned session's model is changed only at the user's request.
    func applicableFallbacks(_ pending: [String: String]) -> [String: String] {
        pending.filter { !isPinned($0.key) }
    }
}
