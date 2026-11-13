import SwiftUI

/// How full one quota window is, read the same way by the usage dashboard,
/// the menu-bar modules and the widget: one rounding rule for the
/// percentage and one set of thresholds for its colour. A missing reading
/// stays unknown and reads "—", so it is never shown as 0%.
struct UsageLevel: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case unknown, normal, high, critical
    }

    /// Percent at and above which a window is `high`.
    static let highThreshold = 70
    /// Percent at and above which a window is `critical`.
    static let criticalThreshold = 90

    /// Percent of the window used, as the provider reports it; nil when
    /// unknown. Values past 100 are kept, since a provider can report
    /// overage.
    let utilization: Double?

    init(utilization: Double?) {
        self.utilization = utilization.flatMap { $0.isFinite ? $0 : nil }
    }

    /// The percentage rounded to the nearest whole percent; `severity` reads
    /// this value, so the colour always agrees with the text.
    var percent: Int? { utilization.map { Int($0.rounded()) } }

    /// "42%", or "—" when unknown.
    var percentText: String { percent.map { "\($0)%" } ?? "—" }

    /// How much of a bar or ring to fill, 0–1; 0 when unknown, which
    /// callers draw as missing rather than empty.
    var fraction: Double { min(max((utilization ?? 0) / 100, 0), 1) }

    var isKnown: Bool { utilization != nil }

    var severity: Severity {
        guard let percent else { return .unknown }
        if percent >= Self.criticalThreshold { return .critical }
        if percent >= Self.highThreshold { return .high }
        return .normal
    }

    /// The level's colour: red when critical, orange when high, `normal`
    /// below that, and `unknown` when there is no reading. Each surface
    /// passes its own resting colours (the dashboard's accent, the menu
    /// bar's monochrome).
    func color(normal: Color, unknown: Color = .secondary) -> Color {
        switch severity {
        case .critical: .red
        case .high: .orange
        case .normal: normal
        case .unknown: unknown
        }
    }
}
