import SwiftUI

/// The Outlook under a provider's heading (`CapacityOutlook`, from
/// `AppState.capacityOutlook`): one line saying until when the provider's
/// sessions run and when they run again. On the Sessions page a click opens
/// it to the timeline of running and paused stretches, the refills, the
/// accounts running out, what comes back, the biggest users and what pausing
/// the heaviest alone would change; whether it is open is kept per provider.
/// On the usage tab (`expandable` false) it is the line alone, and a click
/// opens the Sessions tab (`accountdockShowSessions`). While pacing to the
/// resets holds sessions (`CapacityOutlook.paced`), the line is the paced
/// one beside the flat-out pause, and the opened panel leads with what
/// pacing runs; `pacing`, when given, is the policy's switch, shown there.
struct CapacityOutlookView: View {
    let outlook: CapacityOutlook
    var expandable = true
    var pacing: Binding<Bool>?
    @AppStorage private var expanded: Bool

    init(provider: AIProviderType, outlook: CapacityOutlook, expandable: Bool = true, pacing: Binding<Bool>? = nil) {
        self.outlook = outlook
        self.expandable = expandable
        self.pacing = pacing
        _expanded = AppStorage(wrappedValue: false, "capacityOutlookExpanded.\(provider.rawValue)")
    }

    /// The collapsed line: the paced one while pacing holds sessions.
    private var line: String { outlook.paced?.line(now: outlook.now) ?? outlook.line }

    /// What "Pace sessions to the resets" does, for its switch here and in
    /// Settings.
    static let pacingHelp = "Keeps total use at what the accounts can carry until their allowances return, by holding the lowest-ranked sessions at their next step and releasing them as room allows, instead of every session running flat out and all of them stopping together. Pinned and starred sessions run first, then those you typed into within the hour, then lighter ones before heavier. Playing a held session runs it now, and the others are chosen around it. Needs pausing at the limit, since the pause gate holds the sessions that wait."

    private var isOpen: Bool { expandable && expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if expandable {
                    expanded.toggle()
                } else {
                    NotificationCenter.default.post(name: .accountdockShowSessions, object: nil)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label(isOpen ? "Outlook at the current rate (\(outlook.rateLine))" : line,
                          systemImage: "hourglass")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expandable
                  ? "Projected at each session's use over its last hour, with every account's 5-hour window, weekly allowance and resets. Click to \(isOpen ? "close" : "open") the outlook."
                  : "Projected at each session's use over its last hour, with every account's 5-hour window, weekly allowance and resets. Click to open the Sessions page.")
            .accessibilityLabel(line)
            if isOpen {
                CapacityOutlookPanel(outlook: outlook, pacing: pacing)
                    .padding(.leading, 18)
            }
        }
    }

    /// Orange once every session is paused or will be within two hours;
    /// pacing that holds sessions keeps them from that.
    private var tint: Color {
        guard outlook.paced == nil, let paused = outlook.allPausedAt,
              paused.timeIntervalSince(outlook.now) < 2 * 3600 else { return .textSecondary }
        return .orange
    }
}

/// The opened Outlook: pacing's switch and what pacing runs, then the
/// flat-out timeline, its legend, the three lists, the biggest users and
/// the what-if.
private struct CapacityOutlookPanel: View {
    let outlook: CapacityOutlook
    var pacing: Binding<Bool>?

    /// The most rows a list shows; the rest are counted.
    private let listLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pacing {
                Toggle("Pace sessions to the resets", isOn: pacing)
                    .toggleStyle(.checkbox)
                    .help(CapacityOutlookView.pacingHelp)
            }
            if let paced = outlook.paced {
                ForEach(Array(paced.details(now: outlook.now).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Without pacing, at the current rate:")
                    .font(.caption2.weight(.semibold))
            }
            if outlook.allPausedAt == nil || outlook.alreadyPaused {
                Text(outlook.line)
            }
            CapacityOutlookTimeline(outlook: outlook)
            legend
            list(refillsTitle, rows: soon(outlook.refillsBefore).map(row))
            list("Running out", rows: outlook.runningOut.map(row))
            list("Coming back", rows: soon(outlook.comingBack).map(row))
            if let biggest = outlook.biggestLine {
                Text(biggest)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let whatIf = outlook.whatIfLine {
                Text(whatIf)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption2)
        .foregroundStyle(.textSecondary)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 4) {
                swatch(.brand)
                Text("running")
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                swatch(CapacityOutlookTimeline.pausedFill)
                Text("paused (short bursts possible where weekly room remains)")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // What each mark under the bar means, in its colour.
        (Text(verbatim: "▲ ").foregroundColor(.brand) + Text("refill   ")
            + Text(verbatim: "△ ").foregroundColor(.secondary) + Text("refill, nothing resumes yet   ")
            + Text(verbatim: "● ").foregroundColor(.secondary) + Text("an account runs out   ")
            + Text(verbatim: "▲ ").foregroundColor(.orange) + Text("everything pauses"))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 14, height: 7)
    }

    /// "Overnight refills" when every refill listed falls between 8 pm and
    /// 8 am, else "Refills".
    private var refillsTitle: String {
        let refills = outlook.refillsBefore
        let night = !refills.isEmpty && refills.allSatisfy { event in
            let hour = Calendar.current.component(.hour, from: event.at)
            return hour >= 20 || hour < 8
        }
        return night ? "Overnight refills" : "Refills"
    }

    /// One list line: the time, the account (nil for the pause, which
    /// spans both columns) and what happens.
    private struct Row {
        let time: String
        let name: String?
        let detail: String
    }

    /// Which of the account's limits still stops sessions after `event`
    /// refilled the other one, and until when: "its 5-hour window is full
    /// until 9:29 pm" after a new week, "its weekly limit is reached until
    /// Sat 5:00 am" after a window refill. Taken from the account's next
    /// refill of the other kind, or its spent event's return.
    private func blockingLimit(after event: CapacityOutlook.Event) -> String {
        let other: CapacityOutlook.Event.Kind = event.kind == .newWeek ? .windowRefill : .newWeek
        let name = event.kind == .newWeek ? "its 5-hour window is full" : "its weekly limit is reached"
        let sameAccount = outlook.events.filter { $0.account == event.account && $0.name == event.name }
        let until = sameAccount.first { $0.kind == other && $0.at > event.at }?.at
            ?? sameAccount.last { ($0.kind == .windowSpent || $0.kind == .weekSpent) && $0.at <= event.at }?.back
        return until.map { "\(name) until \(UsageFormat.clock($0, now: outlook.now))" } ?? name
    }

    /// The events of the next `CapacityOutlookTimeline.longestView`, as the
    /// bar shows, plus the resume wherever it falls, so the refill lists
    /// across days stay readable; accounts running out are listed whenever
    /// they do, being few and what the outlook turns on.
    private func soon(_ events: [CapacityOutlook.Event]) -> [CapacityOutlook.Event] {
        let end = outlook.now.addingTimeInterval(CapacityOutlookTimeline.longestView)
        return events.filter { $0.at <= end || $0 == outlook.resume }
    }

    private func row(_ event: CapacityOutlook.Event) -> Row {
        let detail: String
        switch event.kind {
        case .windowRefill, .newWeek:
            var text = event.kind == .newWeek ? "new week — 100% available" : "5-hour window"
            if event == outlook.resume {
                text = (event.kind == .newWeek ? "new week" : "5-hour window") + "   ← sessions resume"
            } else if let runs = event.runs {
                text += " — runs about \(UsageFormat.duration(runs))"
            } else if !outlook.bringsRoom(event) {
                text += " — nothing resumes yet: " + blockingLimit(after: event)
            }
            detail = text
        case .windowSpent:
            detail = "5-hour window" + (event.back.map { " — back \(UsageFormat.clock($0, now: outlook.now))" } ?? "")
        case .weekSpent:
            detail = "weekly limit" + (event.back.map { " — back \(UsageFormat.clock($0, now: outlook.now))" } ?? "")
        case .allPaused:
            detail = "all accounts spent — every session pauses"
        }
        return Row(time: time(event.at), name: event.kind == .allPaused ? nil : event.name ?? "an account", detail: detail)
    }

    /// The time of day within the next 20 hours, else with its weekday.
    private func time(_ date: Date) -> String {
        date.timeIntervalSince(outlook.now) < 20 * 3600
            ? date.formatted(date: .omitted, time: .shortened) : UsageFormat.clock(date, now: outlook.now)
    }

    @ViewBuilder
    private func list(_ title: String, rows: [Row]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(Array(rows.prefix(listLimit).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(verbatim: row.time)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            if let name = row.name {
                                Text(verbatim: name)
                                    .lineLimit(1)
                                Text(verbatim: row.detail)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(verbatim: row.detail)
                                    .gridCellColumns(2)
                            }
                        }
                    }
                }
                .padding(.leading, 8)
                if rows.count > listLimit {
                    Text("and \(rows.count - listLimit) more")
                        .padding(.leading, 8)
                }
            }
        }
    }
}

/// The span from now to just past the resume (or the whole horizon) as one
/// bar of running and paused stretches, with hour labels above it, how long
/// each paused stretch lasts written in it, and a tick below it at each
/// refill, account running out, the pause and the resume, each with its time
/// where there is room; a line under the bar gives the main pause's start,
/// end and length.
private struct CapacityOutlookTimeline: View {
    let outlook: CapacityOutlook

    static let pausedFill = Color.orange.opacity(0.28)
    /// The least room between two hour labels.
    private let labelSpacing: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("now")
                Spacer()
                Text(verbatim: endLabel)
            }
            Canvas { context, size in draw(&context, size: size) }
                .frame(height: 50)
            if let pause = pauseSummary {
                Text(verbatim: pause)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(outlook.line)
    }

    /// How far ahead the bar reaches: to just past the resume, but never
    /// more than `longestView`, so a resume days away does not shrink the
    /// coming hours, where 5-hour windows refill, to slivers. The pause
    /// line under the bar names the resume whatever its distance.
    static let longestView: TimeInterval = 24 * 3600
    private var viewEnd: Date { min(outlook.spanEnd, outlook.now.addingTimeInterval(Self.longestView)) }
    private var span: TimeInterval { max(60, viewEnd.timeIntervalSince(outlook.now)) }

    /// The longest paused stretch: from everything pausing to the resume.
    /// The pause from its first paused stretch to the resume: its start,
    /// end, and the time paused in it, with the short runs between
    /// ("Paused 8:28 pm → 10:59 pm · 2 hr paused, short runs at 9:10 pm and
    /// 9:29 pm"); the longest paused stretch when nothing resumes in view.
    private var pauseSummary: String? {
        let end = outlook.resume?.at
        let paused = outlook.segments.filter { segment in !segment.running && (end.map { segment.start < $0 } ?? true) }
        guard let first = paused.first else { return nil }
        let until = end ?? paused.map(\.end).max() ?? first.end
        let total = paused.reduce(0) { $0 + min($1.end, until).timeIntervalSince($1.start) }
        let runs = outlook.segments.filter { $0.running && $0.start > first.start && $0.start < until }
        var text = "Paused \(UsageFormat.clock(first.start, now: outlook.now)) → \(UsageFormat.clock(until, now: outlook.now)) · \(UsageFormat.duration(total)) paused"
        if !runs.isEmpty {
            let times = runs.prefix(3).map { UsageFormat.clock($0.start, now: outlook.now) }
            text += ", short runs at " + ListFormatter.localizedString(byJoining: times)
        }
        return text
    }

    /// A tick's time label: "8:54", or "8:54 am" for the pause and resume.
    private func tickLabel(_ date: Date, emphasised: Bool) -> String {
        var style = Date.FormatStyle().hour().minute()
        if !Calendar.current.isDate(date, inSameDayAs: outlook.now), emphasised { style = style.weekday(.abbreviated) }
        let text = date.formatted(style)
        return emphasised ? text : text.replacingOccurrences(of: " am", with: "").replacingOccurrences(of: " pm", with: "")
            .replacingOccurrences(of: "\u{202F}am", with: "").replacingOccurrences(of: "\u{202F}pm", with: "")
    }

    /// The time at the bar's right edge, the end of its span, which runs on
    /// past the resume: "11:29 pm", "Tue 9 pm". The resume has its own
    /// labelled arrow.
    private var endLabel: String {
        let date = viewEnd
        let minute = Calendar.current.component(.minute, from: date)
        let sameDay = Calendar.current.isDate(date, inSameDayAs: outlook.now)
        var style = Date.FormatStyle().hour()
        if minute != 0 { style = style.minute() }
        if !sameDay { style = style.weekday(.abbreviated) }
        return date.formatted(style) + (viewEnd < outlook.spanEnd ? " →" : "")
    }

    private func x(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(max(0, min(1, date.timeIntervalSince(outlook.now) / span))) * width
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let barTop: CGFloat = 14, barHeight: CGFloat = 13
        // Hour labels, every 1, 2, 3, 6, 12 or 24 hours as the width allows.
        let hours = [1.0, 2, 3, 6, 12, 24].first { span / ($0 * 3600) * Double(labelSpacing) <= Double(width) } ?? 24
        let calendar = Calendar.current
        var mark = calendar.dateInterval(of: .hour, for: outlook.now)?.end ?? outlook.now
        while Double(calendar.component(.hour, from: mark)).truncatingRemainder(dividingBy: hours) != 0 {
            mark = mark.addingTimeInterval(3600)
        }
        while mark < viewEnd {
            let position = x(mark, width: width)
            if position > 12 && position < width - 12 {
                let label = hours >= 24 ? mark.formatted(.dateTime.weekday(.abbreviated)) : mark.formatted(.dateTime.hour())
                context.draw(Text(verbatim: label).font(.caption2).foregroundColor(.secondary),
                             at: CGPoint(x: position, y: 0), anchor: .top)
            }
            mark = mark.addingTimeInterval(hours * 3600)
        }
        // The bar: paused underneath, running stretches over it, each at
        // least two points wide so a burst of minutes shows.
        let bar = CGRect(x: 0, y: barTop, width: width, height: barHeight)
        let shape = Path(roundedRect: bar, cornerRadius: AppStyle.barCornerRadius)
        context.fill(shape, with: .color(Self.pausedFill))
        var clipped = context
        clipped.clip(to: shape)
        for segment in outlook.segments where segment.running {
            let start = x(segment.start, width: width)
            let end = max(x(segment.end, width: width), start + 2)
            clipped.fill(Path(CGRect(x: start, y: barTop, width: end - start, height: barHeight)), with: .color(.brand))
        }
        // How long each paused stretch lasts, inside it where it fits.
        for segment in outlook.segments where !segment.running {
            let start = x(segment.start, width: width), end = x(segment.end, width: width)
            let label = UsageFormat.compactDuration(segment.end.timeIntervalSince(segment.start))
            let text = context.resolve(Text(verbatim: label).font(.system(size: 9, weight: .semibold)).foregroundColor(.orange))
            guard text.measure(in: CGSize(width: 200, height: 20)).width + 8 <= end - start else { continue }
            clipped.draw(text, at: CGPoint(x: (start + end) / 2, y: barTop + barHeight / 2), anchor: .center)
        }
        // A tick under each event, with its time where it does not crowd a
        // neighbour's; the pause and the resume are labelled first.
        let ticks = outlook.events.filter { $0.kind != .windowSpent && $0.at <= viewEnd }
        let tickTop = barTop + barHeight + 2
        // A refill that lets sessions run is a filled arrow in the brand
        // colour; one after which nothing runs yet, as a new week while the
        // account's 5-hour window is still full, is an outline in grey. An
        // account running out while others carry the sessions is a small
        // grey dot, since nothing pauses there; only the moment every
        // session pauses is an orange arrow.
        for event in ticks {
            let position = x(event.at, width: width)
            if event.kind == .weekSpent {
                let dot = Path(ellipseIn: CGRect(x: position - 2, y: tickTop + 2, width: 4, height: 4))
                context.fill(dot, with: .color(.secondary))
                continue
            }
            var tick = Path()
            tick.move(to: CGPoint(x: position, y: tickTop))
            tick.addLine(to: CGPoint(x: position - 3.5, y: tickTop + 6))
            tick.addLine(to: CGPoint(x: position + 3.5, y: tickTop + 6))
            tick.closeSubpath()
            if event.isRefill, !outlook.bringsRoom(event) {
                context.stroke(tick, with: .color(.secondary), lineWidth: 1)
            } else {
                context.fill(tick, with: .color(event.isRefill ? .brand : .orange))
            }
        }
        func emphasised(_ event: CapacityOutlook.Event) -> Bool {
            // A refill that brings no room keeps its time only where nothing
            // else wants the space; see the tick loop above.
            event.kind == .allPaused || event.at == outlook.resume?.at
        }
        var taken: [ClosedRange<CGFloat>] = []
        for event in ticks.sorted(by: { emphasised($0) && !emphasised($1) }) {
            let position = x(event.at, width: width)
            let strong = emphasised(event)
            let text = context.resolve(Text(verbatim: tickLabel(event.at, emphasised: strong))
                .font(.system(size: 9, weight: strong ? .semibold : .regular))
                .foregroundColor(strong ? (event.kind == .allPaused ? .orange : .brand) : .secondary))
            let half = text.measure(in: CGSize(width: 200, height: 20)).width / 2 + 2
            let left = min(max(position, half), width - half)
            let range = (left - half)...(left + half)
            guard !taken.contains(where: { $0.overlaps(range) }) else { continue }
            taken.append(range)
            context.draw(text, at: CGPoint(x: left, y: tickTop + 7), anchor: .top)
        }
    }
}
