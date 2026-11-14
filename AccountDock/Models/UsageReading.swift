import Foundation

/// A usage reading in the form every provider shares: the windows the
/// account's allowance is counted in (`Window`: a session window, a long
/// window, and long windows that only some models draw on), the extra usage
/// past the plan, the limit resets the account holds, and the model limits
/// with their share of the long window.
///
/// Each provider's reply converts into it (`init(_:)`), and it converts
/// back into that reply's form (`response`) for the readers that still
/// take it; the two conversions keep every window, percent, reset and
/// length. Saved usage snapshots hold it (`PersistedUsageSnapshot`).
struct UsageReading: Codable {
    enum Kind: String, Codable {
        /// The short window, such as Claude's five hours.
        case session
        /// The long window the whole plan is counted in, such as a week.
        case long
        /// A long window only some models draw on.
        case model
    }

    struct Window: Codable, Equatable {
        var kind: Kind
        /// The window's name in the reply it came from, such as `five_hour`
        /// or `seven_day_opus`, which also names it on the way back.
        var label: String
        /// The percent of the window used; nil when the reply gave none.
        var percent: Double?
        var resetsAt: Date?
        /// The window's length, when the reply gives it.
        var length: TimeInterval?
    }

    var windows: [Window]
    var extraUsage: ExtraUsage?
    var limitResets: LimitResets?
    /// Every limit the provider applies, including long-window limits
    /// scoped to one model, as the reply lists them.
    var modelLimits: [UsageLimit]?
    /// Each scoped limit's share of the long window, by its index in
    /// `modelLimits`.
    var modelLimitShares: [WeeklyScopedShare]?

    /// The session window, when the account has one.
    var session: Window? { windows.first { $0.kind == .session } }
    /// The long window.
    var long: Window? { windows.first { $0.kind == .long } }

    /// The reply's windows in the order they are listed, with their kind;
    /// read by both conversions.
    private static var replyWindows: [(label: String, kind: Kind, path: KeyPath<UsageAPIResponse, UsageWindow?>)] {
        [
            ("five_hour", .session, \.fiveHour),
            ("seven_day", .long, \.sevenDay),
            ("seven_day_oauth_apps", .model, \.sevenDayOauthApps),
            ("seven_day_opus", .model, \.sevenDayOpus),
            ("seven_day_sonnet", .model, \.sevenDaySonnet),
            ("seven_day_cowork", .model, \.sevenDayCowork),
            ("iguana_necktie", .model, \.iguanaNecktie),
        ]
    }

    /// A reply in the form the providers' readers return.
    init(_ response: UsageAPIResponse) {
        windows = Self.replyWindows.compactMap { label, kind, path in
            response[keyPath: path].map { window in
                Window(kind: kind, label: label, percent: window.utilization, resetsAt: window.resetsAtDate,
                       length: window.windowSeconds.map(TimeInterval.init))
            }
        }
        extraUsage = response.extraUsage
        limitResets = response.limitResets
        modelLimits = response.limits
        modelLimitShares = response.weeklyScopedShares
    }

    /// The reading in the form the providers' readers return, for the
    /// readers that still take it.
    var response: UsageAPIResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func window(_ label: String) -> UsageWindow? {
            windows.first { $0.label == label }.map { window in
                UsageWindow(utilization: window.percent, resetsAt: window.resetsAt.map(formatter.string(from:)),
                            windowSeconds: window.length.map { Int($0) })
            }
        }
        return UsageAPIResponse(
            fiveHour: window("five_hour"), sevenDay: window("seven_day"),
            sevenDayOauthApps: window("seven_day_oauth_apps"), sevenDayOpus: window("seven_day_opus"),
            sevenDaySonnet: window("seven_day_sonnet"), sevenDayCowork: window("seven_day_cowork"),
            iguanaNecktie: window("iguana_necktie"), extraUsage: extraUsage,
            limits: modelLimits, weeklyScopedShares: modelLimitShares, limitResets: limitResets
        )
    }
}

/// One account's saved usage snapshot, kept in the app's defaults by
/// `AppState.saveUsageSnapshots` and read back at launch by
/// `loadUsageSnapshots`. It holds the reading as a `UsageReading`
/// (`reading`); a snapshot saved in the reply's form (`usage`) still loads,
/// converted.
struct PersistedUsageSnapshot: Codable {
    let reading: UsageReading
    let updatedAt: Date
    /// `accountWholeReadings`; absent in a snapshot saved without one.
    var wholeAt: Date?
    var wholeLongUtilization: Double?
    /// Whether the reading was cleared at a reset no reading has
    /// confirmed yet (`accountsAwaitingPostResetVerification`): its
    /// cleared windows then read 0% with no countdown, which
    /// `loadUsageSnapshots` must not take for a reading.
    var resetUnverified: Bool?

    /// The reading in the form the providers' readers return.
    var usage: UsageAPIResponse { reading.response }

    init(usage: UsageAPIResponse, updatedAt: Date, wholeAt: Date? = nil, wholeLongUtilization: Double? = nil,
         resetUnverified: Bool? = nil) {
        reading = UsageReading(usage)
        self.updatedAt = updatedAt
        self.wholeAt = wholeAt
        self.wholeLongUtilization = wholeLongUtilization
        self.resetUnverified = resetUnverified
    }

    private enum CodingKeys: String, CodingKey {
        case reading, usage, updatedAt, wholeAt, wholeLongUtilization, resetUnverified
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let reading = try values.decodeIfPresent(UsageReading.self, forKey: .reading) {
            self.reading = reading
        } else {
            reading = UsageReading(try values.decode(UsageAPIResponse.self, forKey: .usage))
        }
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        wholeAt = try values.decodeIfPresent(Date.self, forKey: .wholeAt)
        wholeLongUtilization = try values.decodeIfPresent(Double.self, forKey: .wholeLongUtilization)
        resetUnverified = try values.decodeIfPresent(Bool.self, forKey: .resetUnverified)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(reading, forKey: .reading)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(wholeAt, forKey: .wholeAt)
        try values.encodeIfPresent(wholeLongUtilization, forKey: .wholeLongUtilization)
        try values.encodeIfPresent(resetUnverified, forKey: .resetUnverified)
    }
}
