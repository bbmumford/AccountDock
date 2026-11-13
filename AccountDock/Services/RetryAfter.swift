import Foundation

/// The time an HTTP `Retry-After` header names, in either of its forms: a
/// number of seconds or an HTTP date. The usage readers pass it on with a
/// throttled reading (`AppState.UsageReadOutcome.throttled`), which waits
/// until then before reading the provider again.
enum RetryAfter {
    static func date(_ value: String, now: Date = Date()) -> Date? {
        let value = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    /// The header's time in `response`, nil when it has none.
    static func date(in response: URLResponse?, now: Date = Date()) -> Date? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap { date($0, now: now) }
    }
}
