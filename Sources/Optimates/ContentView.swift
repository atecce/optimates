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
            List(filtered, id: \.self, selection: $ticker) { Text($0.uppercased()) }
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
            if let ticker {
                Dashboard(ticker: ticker).id(ticker)
            } else {
                Text("Choose a company").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView { loads += 1 }
        }
        .task(id: loads) {
            loading = true
            defer { loading = false }
            do {
                tickers = try await API.current().tickers()
                error = nil
                // EQUITIES_TICKER=aapl opens a company at launch (simulator.sh).
                if let t = ProcessInfo.processInfo.environment["EQUITIES_TICKER"]?.uppercased(), tickers.contains(t) {
                    ticker = t
                }
            } catch where isCancellation(error) {
                // A newer load replaces this one.
            } catch {
                tickers = []
                self.error = describe(error)
                // Nothing configured, as on a new phone: ask.
                switch error {
                case APIError.signIn: showSettings = true
                default: break
                }
            }
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
    @State private var error: String?
    // Kept across companies, and across launches.
    @AppStorage("side") private var side = Side.stocks
    @AppStorage("period") private var period = FlowPeriod.quarter

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
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                ForEach(side == .stocks ? stocks : flows, id: \.title) { spec in
                    Panel(title: "\(ticker.uppercased()) \(side.rawValue): \(spec.title) (\(currency))",
                          series: spec.lines.map { name, source in
                              Series(name: name, points: data?[currency]?[source] ?? [])
                          },
                          loading: data == nil && error == nil,
                          format: spec.format ?? .money(currency), log: spec.log)
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
        }
        .task {
            do {
                let fetched = try await fetchCompany(ticker, sources: allSources, periods: [.pointInTime, .quarter, .year])
                // The company's reporting currency: USD if it has it, else
                // the one with the most series (a Tokyo listing's JPY).
                if fetched[currency] == nil {
                    currency = fetched.max { a, b in a.value.count < b.value.count }?.key ?? currency
                }
                data = fetched
            } catch where isCancellation(error) {
                // Shown again, the view loads again.
            } catch {
                self.error = describe(error)
            }
        }
    }
}

enum Format {
    case money(String), ratio, percent

    func label(_ v: Double) -> String {
        switch self {
        case let .money(code): return "\(code) " + v.formatted(.number.notation(.compactName))
        case .ratio: return v.formatted(.number.precision(.fractionLength(0...1)))
        case .percent: return v.formatted(.percent.precision(.fractionLength(0)))
        }
    }
}

struct Panel: View {
    let title: String
    let series: [Series]
    let loading: Bool
    let format: Format
    var log = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            Chart {
                ForEach(series) { s in
                    ForEach(s.points, id: \.time) { p in
                        // A log scale cannot show zero or negative values.
                        if !log || p.value > 0 {
                            LineMark(x: .value("Date", p.time), y: .value("Value", p.value))
                                .foregroundStyle(by: .value("Series", s.name))
                        }
                    }
                }
            }
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
    }
}
