import Charts
import SwiftUI

struct ContentView: View {
    @State private var tickers: [String] = []
    @State private var ticker: String?
    @State private var search = ""
    @State private var error: String?
    @State private var loading = true
    @State private var showSettings = false
    /// Bumped after the settings change, to load the companies again.
    @State private var loads = 0

    init() {
        // Clears what an earlier version kept for InfluxDB.
        _ = ServerSettings.load()
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $ticker) {
                if search.isEmpty {
                    Label("Portfolio", systemImage: "chart.pie").tag(PortfolioView.tag)
                    Label("π and r", systemImage: "percent").tag(MacroView.tag)
                    Label("Real estate", systemImage: "house").tag(RealEstateView.tag)
                    Label("Yield curve", systemImage: "chart.line.uptrend.xyaxis").tag(YieldCurveView.tag)
                }
                ForEach(filtered, id: \.self) { Text($0.uppercased()).tag($0) }
            }
                .searchable(text: $search, placement: .sidebar)
                .navigationSplitViewColumnWidth(min: 120, ideal: 150)
                // In the list, so a phone shows it too (its detail pane is
                // hidden until a company is picked).
                .overlay {
                    if loading {
                        ProgressView()
                    } else if let error {
                        VStack(spacing: 12) {
                            Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Server settings") { showSettings = true }
                        }
                        .padding()
                    }
                }
                .toolbar {
                    ToolbarItem {
                        Button { showSettings = true } label: { Label("Server", systemImage: "gearshape") }
                    }
                }
        } detail: {
            if ticker == PortfolioView.tag {
                PortfolioView()
            } else if ticker == MacroView.tag {
                MacroView()
            } else if ticker == RealEstateView.tag {
                RealEstateView()
            } else if ticker == YieldCurveView.tag {
                YieldCurveView()
            } else if let ticker {
                Dashboard(ticker: ticker).id(ticker)
            } else {
                Text("Choose a company").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView { loads += 1 }
        }
        .task(id: loads) {
            // The list kept from last time, at once; then the API's.
            if tickers.isEmpty, let (kept, _) = ReplyCache.shared.get(Equities_V1_TickersResponse.self, "tickers") {
                tickers = kept.tickers
                openFromEnvironment()
            }
            loading = tickers.isEmpty
            defer { loading = false }
            do {
                let reply = try await ReplyCache.shared.fetch("tickers", .tickers, Equities_V1_TickersRequest())
                tickers = reply.tickers
                error = nil
                openFromEnvironment()
                // Through to the API: bring the pinned replies up to date.
                await ReplyCache.shared.refreshPinned()
            } catch where isCancellation(error) {
                // A newer load replaces this one.
            } catch {
                // With a kept list, keep showing it (offline, say).
                if tickers.isEmpty { self.error = describe(error) }
                // Nothing configured, as on a new phone: ask.
                switch error {
                case APIError.signIn: showSettings = true
                default: break
                }
            }
        }
    }

    /// EQUITIES_TICKER=aapl opens a company at launch (simulator.sh), and
    /// EQUITIES_TICKER=portfolio the portfolio, EQUITIES_TICKER=macro π and r.
    private func openFromEnvironment() {
        guard ticker == nil, let t = ProcessInfo.processInfo.environment["EQUITIES_TICKER"]?.uppercased() else { return }
        switch t {
        case "PORTFOLIO": ticker = PortfolioView.tag
        case "MACRO": ticker = MacroView.tag
        case "REALESTATE": ticker = RealEstateView.tag
        case "YIELDCURVE": ticker = YieldCurveView.tag
        default: if tickers.contains(t) { ticker = t }
        }
    }

    private var filtered: [String] {
        search.isEmpty ? tickers : tickers.filter { $0.localizedCaseInsensitiveContains(search) }
    }
}

/// The two sides of a company's accounts: stocks are levels at a point in
/// time (the balance sheet, market value), flows are what changes them over
/// a period (the income and cash flow statements).
enum Side: String, CaseIterable, Identifiable {
    case stocks, flows
    var id: Self { self }
}

/// The period of a flow: a quarter or a year (stored as `3m`, `12m`).
enum FlowPeriod: String, CaseIterable, Identifiable {
    case quarter = "3m", year = "12m"
    var id: Self { self }
    var label: String { self == .quarter ? "Quarter" : "Year" }
    var proto: Equities_V1_Period { self == .quarter ? .quarter : .year }
}

/// The dates the charts show, as Grafana's time picker: the last year, five
/// or ten, all of it, or a range of your own.
enum DateRange: String, CaseIterable, Identifiable {
    case year = "1Y", fiveYears = "5Y", tenYears = "10Y", all = "All", custom = "Custom"
    var id: Self { self }

    /// The dates, ending today; nil for all of them. `from` and `to` are the
    /// custom range's.
    func dates(from: Date, to: Date, now: Date = Date()) -> ClosedRange<Date>? {
        let back = { (years: Int) in Calendar.current.date(byAdding: .year, value: -years, to: now)! ... now }
        switch self {
        case .year: return back(1)
        case .fiveYears: return back(5)
        case .tenYears: return back(10)
        case .all: return nil
        case .custom: return min(from, to) ... max(from, to)
        }
    }
}

/// One chart's worth: what equities.json shows in a panel.
struct PanelSpec {
    let title: String
    let lines: [(String, Source)]
    var format: Format? = nil   // money in the company's currency unless set
    var log = false
}

/// The panels of equities.json for one company, stocks and flows on two
/// tabs. Each stock panel has a flow panel at the same position, the flows
/// that change it, as in the dashboard's rows.
struct Dashboard: View {
    let ticker: String
    @State private var currency = "USD"
    /// Everything the two tabs draw, fetched in one query when the company
    /// opens: switching tabs, periods or currencies fetches nothing.
    @State private var data: CompanyData?
    /// When the API sent what's shown, if it came from the device's cache and
    /// the API hasn't answered since; why not, if it failed.
    @State private var keptFrom: Date?
    @State private var notUpdated: String?
    @State private var error: String?
    // Kept across companies, and across launches.
    @AppStorage("side") private var side = Side.stocks
    @AppStorage("period") private var period = FlowPeriod.quarter
    @AppStorage("range") private var range = DateRange.all
    /// The pinned replies (Pins): this company's is "dashboard/<TICKER>".
    @AppStorage(Pins.defaultsKey) private var pins = Pins.initial
    /// The custom range, as seconds since 1970 (what AppStorage keeps).
    @AppStorage("rangeFrom") private var rangeFrom = Date().addingTimeInterval(-10 * 365.25 * 86_400).timeIntervalSince1970
    @AppStorage("rangeTo") private var rangeTo = Date().timeIntervalSince1970
    /// The crosshair, shared by every panel.
    @State private var selected: Date?

    private func pit(_ item: Equities_V1_Item) -> Source { .reported(item, .pointInTime) }
    private func flow(_ item: Equities_V1_Item) -> Source { .reported(item, period.proto) }

    /// Every line of both tabs, for both flow periods: what to fetch.
    private var allSources: [Source] {
        (stocks + flows).flatMap { $0.lines.map(\.1) }
            + flows.flatMap { $0.lines.map(\.1) }.compactMap {
                if case let .reported(item, _) = $0 { return .reported(item, .year) }
                return nil
            }
    }

    private var currencies: [String] { (data?.keys).map { $0.sorted() } ?? [] }

    private var stocks: [PanelSpec] {[
        PanelSpec(title: "equity and debt", lines: [
            ("total assets", pit(.totalAssets)),
            ("total liabilities", pit(.totalLiabilities)),
            ("stockholders' equity", pit(.stockholdersEquity)),
            ("total debt", pit(.totalDebt)),
        ]),
        PanelSpec(title: "cash and working capital", lines: [
            ("cash", pit(.cashAndCashEquivalents)),
            ("marketable securities", pit(.marketableSecurities)),
            ("receivables", pit(.accountsReceivableNet)),
            ("inventories", pit(.inventories)),
        ]),
        PanelSpec(title: "long-lived assets", lines: [
            ("property and equipment", pit(.propertyAndEquipmentNet)),
            ("goodwill", pit(.goodwill)),
            ("intangibles", pit(.intangibleAssetsNet)),
        ]),
        PanelSpec(title: "market value and book value (log scale)", lines: [
            ("market cap", .market(.marketCap)),
            ("book value", pit(.stockholdersEquity)),
        ], log: true),
        PanelSpec(title: "price-to-book", lines: [
            ("price-to-book", .market(.priceToBook)),
        ], format: .ratio),
    ]}

    private var flows: [PanelSpec] {[
        PanelSpec(title: "income and returns to shareholders", lines: [
            ("revenue", flow(.revenue)),
            ("operating income", flow(.operatingIncome)),
            ("net income", flow(.netIncome)),
            ("buybacks", flow(.paymentsRelatedToRepurchasesOfCommonStock)),
            ("dividends", flow(.dividendsPaid)),
        ]),
        PanelSpec(title: "cash", lines: [
            ("operating", flow(.netCashProvidedByOperatingActivities)),
            ("investing", flow(.netCashUsedInInvestingActivities)),
            ("financing", flow(.netCashUsedInFinancingActivities)),
        ]),
        PanelSpec(title: "investment", lines: [
            ("capex", flow(.purchasesRelatedToPropertyAndEquipmentAndIntangibleAssets)),
            ("depreciation and amortization", flow(.depreciationAndAmoritization)),
            ("acquisitions", flow(.acquisitionsNetOfCashAcquired)),
        ]),
        // Always the last four quarters, whatever the period picked.
        PanelSpec(title: "return on equity and earnings yield (last four quarters)", lines: [
            ("return on equity", .market(.returnOnEquity)),
            ("earnings yield", .market(.earningsYield)),
        ], format: .percent),
    ]}

    /// A stored time as a date, for a DatePicker.
    private func date(_ seconds: Binding<Double>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: seconds.wrappedValue) },
                set: { seconds.wrappedValue = $0.timeIntervalSince1970 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Side", selection: $side) {
                    ForEach(Side.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if side == .flows {
                    Picker("Period", selection: $period) {
                        ForEach(FlowPeriod.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Picker("Dates", selection: $range) {
                    ForEach(DateRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if range == .custom {
                    HStack {
                        DatePicker("From", selection: date($rangeFrom), displayedComponents: .date)
                        DatePicker("To", selection: date($rangeTo), displayedComponents: .date)
                    }
                    .font(.callout)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                if let keptFrom {
                    // From the device: the API hasn't answered yet, or couldn't.
                    Text("Saved \(keptFrom.formatted(.relative(presentation: .named)))" + (notUpdated.map { ": not updated, " + $0 } ?? ", updating…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(side == .stocks ? stocks : flows, id: \.title) { spec in
                    Panel(title: "\(ticker.uppercased()) \(side.rawValue): \(spec.title) (\(currency))",
                          series: spec.lines.map { name, source in
                              Series(name: name, points: data?[currency]?[source] ?? [])
                          },
                          loading: data == nil && error == nil,
                          format: spec.format ?? .money(currency), log: spec.log,
                          range: range.dates(from: Date(timeIntervalSince1970: rangeFrom), to: Date(timeIntervalSince1970: rangeTo)),
                          selected: $selected)
                }
            }
            .padding()
        }
        .navigationTitle(ticker.uppercased())
        .toolbar {
            if currencies.count > 1 {
                Picker("Currency", selection: $currency) {
                    ForEach(currencies, id: \.self) { Text($0) }
                }
            }
            PinButton(key: "dashboard/\(ticker.uppercased())", pins: $pins)
        }
        .task {
            // What the device kept from last time, at once; then the API's.
            let key = "dashboard/\(ticker.uppercased())"
            if data == nil, let (kept, fetched) = ReplyCache.shared.get(Equities_V1_DashboardResponse.self, key) {
                show(companyData(kept))
                keptFrom = fetched
            }
            do {
                let request = dashboardRequest(ticker, sources: allSources, periods: [.pointInTime, .quarter, .year])
                let reply = try await ReplyCache.shared.fetch(key, .dashboard, request)
                show(companyData(reply))
                (keptFrom, notUpdated) = (nil, nil)
            } catch where isCancellation(error) {
                // Shown again, the view loads again.
            } catch {
                if data == nil { self.error = describe(error) } else { notUpdated = describe(error) }
            }
        }
    }

    private func show(_ fetched: CompanyData) {
        // On first showing, the company's reporting currency: the one with
        // the most series (Toyota's yen, not the dollars of two old 20-Fs);
        // after that, whichever was picked, unless the data lacks it.
        if data == nil || fetched[currency] == nil {
            currency = fetched.max { a, b in a.value.count < b.value.count }?.key ?? currency
        }
        data = fetched
    }
}

enum Format {
    /// `percent` for fractions (0.03), `points` for values already in percent
    /// (3, as FRED publishes rates).
    case money(String), ratio, percent, points

    func label(_ v: Double) -> String {
        switch self {
        case let .money(code): return "\(code) " + v.formatted(.number.notation(.compactName))
        case .ratio: return v.formatted(.number.precision(.fractionLength(0...1)))
        case .percent: return v.formatted(.percent.precision(.fractionLength(0)))
        case .points: return v.formatted(.number.precision(.fractionLength(0...1))) + "%"
        }
    }
}

/// Line colours, in the order of a panel's lines: set, not left to Charts,
/// so the values under the crosshair can wear their line's colour.
private let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink]

struct Panel: View {
    let title: String
    let series: [Series]
    let loading: Bool
    let format: Format
    var log = false
    /// The dates shown; nil for all. The axes fit what's in it.
    var range: ClosedRange<Date>? = nil
    /// The crosshair: the date a finger is on, in any panel, shared by all of
    /// them (Grafana's shared crosshair). nil when no finger is down.
    @Binding var selected: Date?

    /// The x axis: the range, or every line's dates.
    private var xDomain: ClosedRange<Date> {
        if let range { return range }
        let times = series.flatMap { $0.points.map(\.time) }
        guard let first = times.min(), let last = times.max() else { return Date() ... Date() }
        return first ... last
    }

    /// A line's points in the range (and above zero on a log scale, which
    /// can't show the rest).
    private func shown(_ s: Series) -> [Point] {
        s.points.filter { (range?.contains($0.time) ?? true) && (!log || $0.value > 0) }
    }

    /// Each line's value at the crosshair (`Series.value(at:)`), from all of
    /// its points: a quarter reported before the range still reads inside it.
    private var readout: [(name: String, color: Color, value: Double)] {
        guard let selected else { return [] }
        return series.enumerated().compactMap { i, s in
            s.value(at: selected).map { (s.name, palette[i % palette.count], $0) }
        }
    }

    private func color(_ i: Int) -> Color { palette[i % palette.count] }

    /// The rule at the crosshair, and its readout.
    @ChartContentBuilder private var crosshair: some ChartContent {
        if let selected {
            RuleMark(x: .value("Date", selected))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    Readout(date: selected, values: readout, format: format)
                }
        }
    }

    /// The lines: one mark a point, as iOS 17 draws them.
    private var markChart: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.element.id) { i, s in
                ForEach(shown(s), id: \.time) { p in
                    LineMark(x: .value("Date", p.time), y: .value("Value", p.value))
                        .foregroundStyle(by: .value("Series", s.name))
                }
            }
            crosshair
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.indices.map(color))
    }

    #if compiler(>=6.0)
    /// The lines as vectorized plots (iOS 18): one plot a line, drawn
    /// together, not one mark a point. Thousands of daily prices draw and
    /// scroll the crosshair much faster. (Built by Xcode Cloud's newer
    /// compiler only: the Mac's Xcode 15 has no LinePlot.)
    ///
    /// Each LinePlot names its series (foregroundStyle(by:), as the marks
    /// do): unnamed, a panel's LinePlots were one series, joined end to start
    /// in one colour (seen on the phone, 2026-11-25). Whether naming keeps
    /// them apart is what the flag (`vectorizedCharts`) is there to see.
    @available(iOS 18, macOS 15, *)
    private var plotChart: some View {
        Chart {
            ForEach(series) { s in
                LinePlot(shown(s), x: .value("Date", \.time), y: .value("Value", \.value))
                    .foregroundStyle(by: .value("Series", s.name))
            }
            crosshair
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.indices.map(color))
    }
    #endif

    /// Vectorized charts, a flag in Settings, off unless turned on: the Mac
    /// can't build or show them, so they're tried on the phone first.
    @AppStorage("vectorizedCharts") private var vectorized = false

    /// The chart: one mark a point, unless the flag is on and the system has
    /// vectorized plots.
    @ViewBuilder private var chart: some View {
        #if compiler(>=6.0)
        if #available(iOS 18, macOS 15, *), vectorized {
            styled(plotChart)
        } else {
            styled(markChart)
        }
        #else
        styled(markChart)
        #endif
    }

    /// What both kinds of chart share: the crosshair, the axes, the legend.
    private func styled(_ chart: some View) -> some View {
        chart
            .chartLegend(.hidden)
            .chartXSelection(value: $selected)
            .chartXScale(domain: xDomain)
            .chartYScale(type: log ? .log : .linear)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(format.label(v)) } }
                }
            }
            .frame(height: 260)
            .overlay { if loading { ProgressView() } }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            chart
            // The legend, drawn here: vectorized plots have no automatic one.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(Array(series.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 4) {
                        Circle().fill(color(i)).frame(width: 8, height: 8)
                        Text(s.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// The values under the crosshair, as Grafana's tooltip: the date, then each
/// line's value in its colour.
private struct Readout: View {
    let date: Date
    let values: [(name: String, color: Color, value: Double)]
    let format: Format

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date.formatted(.dateTime.year().month(.abbreviated).day()))
                .font(.caption.bold())
                .foregroundStyle(Color.primary)
            ForEach(values, id: \.name) { v in
                HStack(spacing: 4) {
                    Circle().fill(v.color).frame(width: 7, height: 7)
                    Text(v.name).foregroundStyle(Color.secondary)
                    Spacer(minLength: 8)
                    Text(format.label(v.value)).monospacedDigit().foregroundStyle(Color.primary)
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 150)
        // Solid: a material has nothing to blur inside a chart, and renders black.
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.5).opacity(0.12))
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
    }
}
