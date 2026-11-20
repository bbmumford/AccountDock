import Foundation

/// Sessions the user marked as priority (the star beside a session on the
/// Sessions page and in an account card's session list), by session ID, so
/// a resumed session with the same ID keeps its mark. With "Pace sessions to
/// the resets", a priority session runs first, beside pinned ones, whatever
/// the target (`SustainablePace.Candidate.Fixed.priority`); nothing else
/// reads the mark. Kept in `UserDefaults` under `defaultsKey` by
/// `AppState.sessionPriorities`, as `SessionPins` keeps pins.
struct SessionPriorities: Codable, Equatable {
    struct Mark: Codable, Equatable {
        /// The provider's raw value.
        var provider: String
        var markedAt: Date
    }

    /// Marks by session ID.
    var sessions: [String: Mark] = [:]

    static let defaultsKey = "app.accountdock.failover.priorities"
    /// A mark whose session has no record yet is kept this long, as its
    /// first record may be written after it was marked.
    static let recordGrace = SessionPins.recordGrace

    func isPriority(_ session: String?) -> Bool {
        session.map { sessions[$0] != nil } ?? false
    }

    /// Priority sessions of one provider.
    func marked(_ provider: AIProviderType) -> Set<String> {
        Set(sessions.filter { $0.value.provider == provider.rawValue }.keys)
    }

    /// Marks or unmarks `session`; returns whether that changed anything.
    @discardableResult
    mutating func set(_ session: String, priority: Bool, provider: AIProviderType, at now: Date) -> Bool {
        if priority {
            guard sessions[session] == nil else { return false }
            sessions[session] = Mark(provider: provider.rawValue, markedAt: now)
            return true
        }
        return sessions.removeValue(forKey: session) != nil
    }

    /// Drops the marks of `provider`'s sessions that no longer have a record
    /// (`recorded`, the session IDs `AgentSessions.records` lists that have
    /// not ended), after `recordGrace`. Returns the sessions unmarked.
    mutating func prune(_ provider: AIProviderType, recorded: Set<String>, now: Date) -> [String] {
        let gone = sessions.filter { session, mark in
            mark.provider == provider.rawValue && !recorded.contains(session)
                && now.timeIntervalSince(mark.markedAt) > Self.recordGrace
        }.keys.sorted()
        for session in gone { sessions[session] = nil }
        return gone
    }

    static func load(_ defaults: UserDefaults = .standard) -> SessionPriorities {
        guard let data = defaults.data(forKey: defaultsKey),
              let marks = try? JSONDecoder().decode(SessionPriorities.self, from: data) else { return SessionPriorities() }
        return marks
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
