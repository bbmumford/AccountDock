import Foundation

/// How a cost, a token count, a time and a span of time are written
/// wherever AccountDock shows one: the usage dashboard, the cost tab, the
/// menu bar, banners, status lines, failover events and the widget.
enum UsageFormat {
    /// "$12.34". A cost above zero but under a cent reads "<$0.01" so it is
    /// not mistaken for none. `wholeDollars` writes "$12" for columns too
    /// narrow for cents.
    static func cost(_ amount: Double, wholeDollars: Bool = false) -> String {
        if wholeDollars { return String(format: "$%.0f", amount) }
        if amount > 0 && amount < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", amount)
    }

    /// "950", "12.3K", "4.5M", "1.2B".
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    // MARK: - Times and spans

    /// A time as AccountDock names one, in the user's locale: the time of
    /// day ("7:59 am") on `now`'s day, the weekday and time ("Mon 7:59 am")
    /// within six days of it, and the weekday, date and time
    /// ("Mon 17 Nov 7:59 am") further off, or on any other day when `dated`,
    /// where a weekday alone could be read as its next occurrence.
    static func clock(_ date: Date, now: Date = Date(), dated: Bool = false) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if !dated, abs(date.timeIntervalSince(now)) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// `clock` with its preposition: "at 7:59 am" on `now`'s day, else
    /// "on Mon 7:59 am".
    static func atClock(_ date: Date, now: Date = Date()) -> String {
        (Calendar.current.isDate(date, inSameDayAs: now) ? "at " : "on ") + clock(date, now: now)
    }

    /// A span in words, to the nearest minute: "40 min", "2 hr", "2 hr 14 min",
    /// "3 d 6 hr". A span above zero reads at least "1 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(seconds > 0 ? 1 : 0, Int((max(0, seconds) / 60).rounded()))
        let days = total / 1440, hours = (total % 1440) / 60, minutes = total % 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) hr" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) hr \(minutes) min" : "\(hours) hr" }
        return "\(minutes) min"
    }

    /// A span in the fixed shape a narrow cell can hold, whole units only:
    /// "5m", "2h 14m", "4d 6h". A span above zero reads at least "1m".
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        let days = whole / 86_400, hours = (whole % 86_400) / 3600, minutes = (whole % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(whole > 0 ? max(minutes, 1) : 0)m"
    }

    /// How far off `date` is and when: "now", "in about 40 min (9:12 am)",
    /// "in about 2 hr 14 min (9:12 am)" within a day, else
    /// "around Mon 9:12 am".
    static func until(_ date: Date, now: Date = Date()) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining >= 30 else { return "now" }
        let when = clock(date, now: now)
        return remaining < 86_400 ? "in about \(duration(remaining)) (\(when))" : "around \(when)"
    }

    /// A usage window's reset as its row names it: "Resets now",
    /// "Resets in 2 hr 14 min" within a day, else the date and time
    /// ("Resets on Mon 17 Nov 7:59 am"), so a long window's weekday cannot be
    /// read as its next occurrence.
    static func reset(_ date: Date, now: Date = Date()) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return "Resets now" }
        guard remaining > 86_400 else { return "Resets in \(duration(remaining))" }
        return "Resets on \(clock(date, now: now, dated: true))"
    }
}
