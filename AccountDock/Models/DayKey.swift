import Foundation

/// The `yyyy-MM-dd` keys usage and cost are stored and looked up by: the
/// local day in the Gregorian calendar, whatever calendar and locale the
/// user has set. `UsageIndex` writes them and the cost views, parsers and
/// `AppState.todayCost` read them, so every side must format a day the same
/// way; a formatter left on the user's calendar writes another year under a
/// Buddhist or Japanese calendar and finds nothing.
enum DayKey {
    /// A formatter for day keys, for a caller that formats many in a loop.
    static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// `DateFormatter` is thread-safe and this one is never changed.
    nonisolated(unsafe) private static let shared = makeFormatter()

    static func string(from date: Date) -> String { shared.string(from: date) }
    static func date(from key: String) -> Date? { shared.date(from: key) }
}
