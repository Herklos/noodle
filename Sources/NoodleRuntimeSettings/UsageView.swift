import Charts
import NoodleCore
import NoodleRuntime
import SwiftUI

/// Everything the Usage window shows, computed from the ledger's days.
struct UsageReport {
    enum Span: String, CaseIterable, Identifiable {
        case week = "7 Days", month = "30 Days", year = "12 Months"
        var id: Self { self }
        var bucket: Calendar.Component { self == .year ? .month : .day }
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case agent = "Bot", harness = "Harness", model = "Model"
        var id: Self { self }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens", cost = "Cost"
        var id: Self { self }
    }

    struct Bar: Identifiable, Equatable {
        let bucket: Date
        let group: String
        let value: Double
        var id: String { "\(bucket.timeIntervalSince1970)|\(group)" }
    }

    struct Row: Identifiable, Equatable {
        let group: String
        let tokens: UsageTokens
        let cost: Double?
        var id: String { group }
    }

    static let otherGroup = "Other"
    /// Groups past this many fold into Other in the chart.
    static let colorCount = 7

    let metric: Metric
    let rows: [Row]
    /// Chart series in legend order: the largest groups by name, then Other.
    let groups: [String]
    let bars: [Bar]
    let tokens: UsageTokens
    let cost: Double?
    let cacheHitRate: Double
    let dailyAverage: Double

    static func range(_ span: Span, now: Date, calendar: Calendar = .current) -> Range<Date> {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        switch span {
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)!..<tomorrow
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)!..<tomorrow
        case .year:
            let month = calendar.dateInterval(of: .month, for: today)!.start
            return calendar.date(byAdding: .month, value: -11, to: month)!..<tomorrow
        }
    }

    init(days: [UsageDay], span: Span, grouping: Grouping, metric: Metric, now: Date, calendar: Calendar = .current) {
        self.metric = metric
        // Bots are told apart by ID; a repeated name gets a number.
        var botLabels: [UUID: String] = [:]
        for (name, ids) in Dictionary(grouping: Set(days.map(\.agentID)), by: { id in days.first { $0.agentID == id }!.agentName }) {
            for (index, id) in ids.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                botLabels[id] = index == 0 ? name : "\(name) (\(index + 1))"
            }
        }
        func group(_ day: UsageDay) -> String {
            switch grouping {
            case .agent: botLabels[day.agentID] ?? day.agentName
            case .harness: HarnessProvider(rawValue: day.harness)?.displayName ?? day.harness
            case .model: day.model.isEmpty ? "Default Model" : day.model
            }
        }
        func value(_ tokens: UsageTokens, _ cost: Double?) -> Double {
            metric == .cost ? cost ?? 0 : Double(tokens.total)
        }
        func sumCost(_ days: [UsageDay]) -> Double? {
            let costs = days.compactMap(\.costUSD)
            return costs.isEmpty ? nil : costs.reduce(0, +)
        }
        rows = Dictionary(grouping: days, by: group).map { group, days in
            Row(group: group, tokens: days.reduce(UsageTokens()) { $0 + $1.tokens }, cost: sumCost(days))
        }
        .sorted { (value($0.tokens, $0.cost), $1.group) > (value($1.tokens, $1.cost), $0.group) }
        // Hues go in name order so a new period or measure does not repaint a
        // group just because its rank changed.
        let named = rows.prefix(Self.colorCount).map(\.group).sorted()
        groups = rows.count > Self.colorCount ? named + [Self.otherGroup] : named
        var sums: [Date: [String: Double]] = [:]
        for day in days {
            let bucket = calendar.dateInterval(of: span.bucket, for: day.day)?.start ?? day.day
            let name = named.contains(group(day)) ? group(day) : Self.otherGroup
            sums[bucket, default: [:]][name, default: 0] += value(day.tokens, day.costUSD)
        }
        let order = groups
        bars = sums.flatMap { bucket, values in values.map { Bar(bucket: bucket, group: $0.key, value: $0.value) } }
            .sorted { ($0.bucket, order.firstIndex(of: $0.group) ?? 0) < ($1.bucket, order.firstIndex(of: $1.group) ?? 0) }
        tokens = days.reduce(UsageTokens()) { $0 + $1.tokens }
        cost = sumCost(days)
        cacheHitRate = tokens.promptTotal > 0 ? Double(tokens.cacheRead) / Double(tokens.promptTotal) : 0
        let range = Self.range(span, now: now, calendar: calendar)
        let dayCount = max(1, calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 1)
        dailyAverage = value(tokens, cost) / Double(dayCount)
    }

    func share(of row: Row) -> Double? {
        let total = rows.reduce(0) { $0 + value(of: $1) }
        return total > 0 ? value(of: row) / total : nil
    }

    private func value(of row: Row) -> Double {
        metric == .cost ? row.cost ?? 0 : Double(row.tokens.total)
    }
}

/// Token use and cost per bot, harness and model, for Noodle and Noodle Hub.
public struct UsageView: View {
    public static let windowID = "usage"

    let history: UsageHistory
    let agents: [AgentRecord]
    @State private var span = UsageReport.Span.month
    @State private var grouping = UsageReport.Grouping.agent
    @State private var metric = UsageReport.Metric.tokens
    @State private var selectedBucket: Date?

    /// Categorical hues in fixed order, stepped for the dark surface; anything past them folds into Other.
    private static let hues: [Color] = ([0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9] as [Int]).map(color)

    /// Spelled out in steps: as one expression, slower compilers give up type-checking it.
    private static func color(_ hex: Int) -> Color {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        return Color(red: red, green: green, blue: blue)
    }

    public init(history: UsageHistory, agents: [AgentRecord]) {
        self.history = history
        self.agents = agents
    }

    public var body: some View {
        let _ = history.revision
        let now = Date()
        let range = UsageReport.range(span, now: now)
        let days = history.days(from: range.lowerBound, to: range.upperBound, agentID: history.agentFilter)
        let report = UsageReport(days: days, span: span, grouping: grouping, metric: metric, now: now)
        Group {
            if days.isEmpty {
                ContentUnavailableView("No Usage", systemImage: "chart.bar.xaxis",
                                       description: Text("No tokens were used in this period."))
            } else {
                VStack(spacing: 0) {
                    summary(report)
                        .padding([.horizontal, .top], 20)
                    chart(report)
                        .frame(minHeight: 200)
                        .padding(20)
                    Divider()
                    breakdown(report)
                        .frame(minHeight: 140)
                }
            }
        }
        .frame(minWidth: 840, minHeight: 560)
        .navigationSubtitle(rangeText(range))
        .toolbar { toolbar() }
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        let filter = Binding(get: { history.agentFilter }, set: { history.agentFilter = $0 })
        ToolbarItem(placement: .principal) {
            Picker("Period", selection: $span) {
                ForEach(UsageReport.Span.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Period")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Bot", selection: filter) {
                Text("All Bots").tag(UUID?.none)
                Divider()
                ForEach(agents) { agent in
                    Label {
                        Text(agent.displayName)
                    } icon: {
                        if let image = BotAvatar.menuImage(for: agent) { Image(nsImage: image) }
                    }
                    .tag(Optional(agent.id))
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 6)
            .help("Bot")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Picker("Group By", selection: $grouping) {
                ForEach(UsageReport.Grouping.allCases) { Text("By \($0.rawValue)").tag($0) }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 6)
            .help("Group By")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Picker("Measure", selection: $metric) {
                ForEach(UsageReport.Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Measure")
        }
    }

    /// The period's first and last day, or first and last month.
    private func rangeText(_ range: Range<Date>) -> String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: range.upperBound) ?? range.upperBound
        let style: Date.IntervalFormatStyle = span == .year
            ? .interval.month(.abbreviated).year()
            : .interval.day().month(.abbreviated).year()
        return (range.lowerBound..<last).formatted(style)
    }

    private func summary(_ report: UsageReport) -> some View {
        HStack(spacing: 0) {
            stat("Tokens", Self.tokenText(report.tokens.total))
            Divider().frame(height: 36)
            stat("Cost", report.cost.map(Self.costText) ?? "—")
                .help("Only harnesses that report cost are included.")
            Divider().frame(height: 36)
            stat("Cache Hits", report.cacheHitRate.formatted(.percent.precision(.fractionLength(0))))
                .help("Share of input tokens read from the cache.")
            Divider().frame(height: 36)
            stat("Input", Self.tokenText(report.tokens.input + report.tokens.cacheWrite))
                .help("Input tokens not read from the cache.")
            Divider().frame(height: 36)
            stat("Output", Self.tokenText(report.tokens.output))
            Divider().frame(height: 36)
            stat("Daily Average", text(report.dailyAverage))
        }
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func chart(_ report: UsageReport) -> some View {
        let unit = span.bucket
        let selected = selectedBucket.map { Calendar.current.dateInterval(of: unit, for: $0)?.start ?? $0 }
        return Chart {
            ForEach(report.bars) { bar in
                BarMark(x: .value("Date", bar.bucket, unit: unit), y: .value(metric.rawValue, bar.value))
                    .foregroundStyle(by: .value(grouping.rawValue, bar.group))
                    .opacity(selected == nil || selected == bar.bucket ? 1 : 0.4)
            }
            if let selected {
                RuleMark(x: .value("Date", selected, unit: unit))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(report.bars.filter { $0.bucket == selected }, date: selected, groups: report.groups)
                    }
            }
        }
        .chartForegroundStyleScale(domain: report.groups, range: report.groups.map { color(for: $0, in: report.groups) })
        .chartXSelection(value: $selectedBucket)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(text(number)) }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
    }

    private func tooltip(_ bars: [UsageReport.Bar], date: Date, groups: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date, format: span == .year ? .dateTime.month(.wide).year() : .dateTime.weekday().day().month())
                .font(.caption.weight(.semibold))
            ForEach(bars.sorted { $0.value > $1.value }) { bar in
                HStack(spacing: 6) {
                    Circle().fill(color(for: bar.group, in: groups)).frame(width: 8, height: 8)
                    Text(bar.group)
                    Spacer(minLength: 12)
                    Text(text(bar.value)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func breakdown(_ report: UsageReport) -> some View {
        Table(report.rows) {
            TableColumn(grouping.rawValue) { row in
                HStack(spacing: 6) {
                    Circle().fill(color(for: row.group, in: report.groups)).frame(width: 8, height: 8)
                    Text(row.group).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Tokens") { row in Text(Self.tokenText(row.tokens.total)) }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Input") { row in Text(Self.tokenText(row.tokens.input + row.tokens.cacheWrite)) }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Output") { row in Text(Self.tokenText(row.tokens.output)) }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Cached") { row in Text(Self.tokenText(row.tokens.cacheRead)) }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Cost") { row in Text(row.cost.map(Self.costText) ?? "—") }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Share") { row in
                Text(report.share(of: row)?.formatted(.percent.precision(.fractionLength(0))) ?? "—")
            }
            .width(min: 64, ideal: 88)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .monospacedDigit()
    }

    private func color(for group: String, in groups: [String]) -> Color {
        guard group != UsageReport.otherGroup, let index = groups.firstIndex(of: group), index < Self.hues.count else { return .gray }
        return Self.hues[index]
    }

    private func text(_ value: Double) -> String {
        metric == .cost ? Self.costText(value) : Self.tokenText(Int(value))
    }

    private static func tokenText(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    private static func costText(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 && value > 0 ? 3 : 2)))
    }
}
