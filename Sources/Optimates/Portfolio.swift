import SwiftUI

/// The owner's brokerage accounts (the API's Holdings, from Plaid): each
/// position's value and unrealized gain. Options are shown by value only, for
/// now; cash and a margin debit by value.
struct PortfolioView: View {
    /// The sidebar's tag for this screen (no ticker looks like it).
    static let tag = "★ portfolio"

    @State private var reply: Equities_V1_HoldingsResponse?
    @State private var keptFrom: Date?
    @State private var notUpdated: String?
    @State private var error: String?
    /// Accounts showing every position, not just the largest.
    @State private var expanded: Set<String> = []

    private static let shownAtFirst = 15

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if let keptFrom {
                Text("Saved \(keptFrom.formatted(.relative(presentation: .named)))" + (notUpdated.map { ": not updated, " + $0 } ?? ", updating…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reply {
                Section {
                    Totals(positions: reply.accounts.flatMap(\.positions), balance: reply.accounts.map(\.balance).reduce(0, +), baseline: reply.baseline, market: reply.market,
                           rates: (reply.annualRate, reply.baselineRate, reply.marketRate), r10: reply.r10Rate)
                } footer: {
                    if reply.syncedUnix > 0 {
                        Text("Synced with the brokerage \(Date(timeIntervalSince1970: TimeInterval(reply.syncedUnix)).formatted(.relative(presentation: .named))). Pull to refresh.")
                    }
                }
                ForEach(reply.accounts, id: \.name) { account in
                    Section {
                        Totals(positions: account.positions, balance: account.balance, baseline: reply.baseline, market: reply.market,
                               rates: (account.annualRate, account.baselineRate, account.marketRate), r10: account.r10Rate)
                        let positions = ordered(account.positions)
                        let all = expanded.contains(account.name)
                        ForEach(Array((all ? positions : Array(positions.prefix(Self.shownAtFirst))).enumerated()), id: \.offset) { _, p in
                            PositionRow(position: p)
                        }
                        if positions.count > Self.shownAtFirst {
                            Button(all ? "Show the largest \(Self.shownAtFirst)" : "Show all \(positions.count)") {
                                if all { expanded.remove(account.name) } else { expanded.insert(account.name) }
                            }
                        }
                    } header: {
                        Text(account.name)
                    }
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .navigationTitle("Portfolio")
        .refreshable { await load(refresh: true) }
        .task {
            if reply == nil, let (kept, fetched) = ReplyCache.shared.get(Equities_V1_HoldingsResponse.self, "holdings") {
                reply = kept
                keptFrom = fetched
            }
            await load(refresh: false)
        }
    }

    /// Shares and shorts by size, then options, then cash.
    private func ordered(_ positions: [Equities_V1_Position]) -> [Equities_V1_Position] {
        func rank(_ k: Equities_V1_PositionKind) -> Int {
            switch k { case .long, .short: return 0; case .option: return 1; default: return 2 }
        }
        return positions.sorted { (rank($0.kind), -abs($0.value)) < (rank($1.kind), -abs($1.value)) }
    }

    @MainActor
    private func load(refresh: Bool) async {
        var request = Equities_V1_HoldingsRequest()
        request.refresh = refresh
        do {
            let fresh = try await ReplyCache.shared.fetch("holdings", .holdings, request)
            reply = fresh
            (keptFrom, notUpdated, error) = (nil, nil, nil)
        } catch where isCancellation(error) {
        } catch {
            if reply == nil { self.error = describe(error) } else { notUpdated = describe(error) }
        }
    }
}

/// Unrealized gain of positions with a known cost: value - cost. Shorts'
/// costs are negative (what the sale brought in), so a short gains as its
/// price falls.
func unrealized(_ positions: [Equities_V1_Position]) -> (gain: Double, cost: Double)? {
    let known = positions.filter { $0.hasCost && ($0.kind == .long || $0.kind == .short) }
    guard !known.isEmpty else { return nil }
    return (known.map { $0.value - $0.cost }.reduce(0, +), known.map { abs($0.cost) }.reduce(0, +))
}

/// Long positions measured against the baseline (the portfolio's r, MINT):
/// their total return, dividends included, against what the baseline made
/// over the same days, distributions included; and how many of the long
/// positions that covers (buys older than Plaid's two years can't be
/// measured).
///
/// Both on the brokerage's cost: it holds every dollar the position took,
/// premiums of exercised options and wash-sale adjustments too, which the
/// buys alone miss. The baseline's growth over the buys' days is applied to
/// it, as if those dollars went in when the shares were bought.
func overBaseline(_ positions: [Equities_V1_Position]) -> (gain: Double, baseline: Double, measured: Int, of: Int)? {
    let longs = positions.filter { $0.kind == .long }
    let measured = longs.filter { $0.hasCost && $0.hasBaselineCost && $0.hasBaselineValue && $0.baselineCost > 0 }
    guard !measured.isEmpty else { return nil }
    return (measured.map { $0.value + $0.dividends - $0.cost }.reduce(0, +),
            measured.map { $0.cost * ($0.baselineValue / $0.baselineCost - 1) }.reduce(0, +),
            measured.count, longs.count)
}

/// The same, against r10: the same dollars compounding at the 10-year
/// Treasury yield of each buy day, the long-run hurdle (no price risk).
func overR10(_ positions: [Equities_V1_Position]) -> (gain: Double, r10: Double)? {
    let measured = positions.filter { $0.kind == .long && $0.hasCost && $0.hasBaselineCost && $0.hasR10Value && $0.baselineCost > 0 }
    guard !measured.isEmpty else { return nil }
    return (measured.map { $0.value + $0.dividends - $0.cost }.reduce(0, +),
            measured.map { $0.cost * ($0.r10Value / $0.baselineCost - 1) }.reduce(0, +))
}

/// "over r₁₀ +$12.00 · +3.3 pts/yr".
func againstR10(_ excess: Double, rate: Double? = nil, base: Double? = nil) -> String {
    against("r₁₀", excess, rate, base)
}

/// The same, against the market (SPY): what the same dollars made in the
/// S&P 500 over the same days, dividends included. Over market less over r
/// is the equity premium those days paid; over market itself is skill, or
/// luck, with beta taken as 1 (Jensen's alpha, in dollars).
func overMarket(_ positions: [Equities_V1_Position]) -> (gain: Double, market: Double, measured: Int, of: Int)? {
    let longs = positions.filter { $0.kind == .long }
    let measured = longs.filter { $0.hasCost && $0.hasBaselineCost && $0.hasMarketValue && $0.baselineCost > 0 }
    guard !measured.isEmpty else { return nil }
    return (measured.map { $0.value + $0.dividends - $0.cost }.reduce(0, +),
            measured.map { $0.cost * ($0.marketValue / $0.baselineCost - 1) }.reduce(0, +),
            measured.count, longs.count)
}

/// "over r +$12.00", or with annual rates "over r +$12.00 · +3.1 pts/yr":
/// the premium on r, your annual rate minus r's (XIRR, CAPITAL.md).
func againstR(_ excess: Double, rate: Double? = nil, base: Double? = nil) -> String {
    against("r", excess, rate, base)
}

/// "over market +$12.00" or "under market -$3.00 · -1.8 pts/yr".
func againstMarket(_ excess: Double, rate: Double? = nil, base: Double? = nil) -> String {
    against("market", excess, rate, base)
}

/// The premium in percentage points a year, "+3.1 pts/yr", when both rates are known.
func premium(_ rate: Double?, _ base: Double?) -> String? {
    guard let rate, let base else { return nil }
    let points = (rate - base) * 100
    return (points >= 0 ? "+" : "") + points.formatted(.number.precision(.fractionLength(1))) + " pts/yr"
}

private func against(_ what: String, _ excess: Double, _ rate: Double?, _ base: Double?) -> String {
    (excess >= 0 ? "over \(what) +" : "under \(what) ") + excess.formatted(.currency(code: "USD"))
        + (premium(rate, base).map { " · " + $0 } ?? "")
}

private func dollars(_ v: Double) -> String { v.formatted(.currency(code: "USD")) }

private func signedDollars(_ v: Double) -> String { (v >= 0 ? "+" : "") + dollars(v) }

private func signedPercent(_ v: Double) -> String {
    v.formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always()))
}

private struct Totals: View {
    let positions: [Equities_V1_Position]
    let balance: Double
    let baseline: String
    let market: String
    /// Annual rates (yours, r's, the market's), from the API.
    var rates: (Double?, Double?, Double?) = (nil, nil, nil)
    /// r10's annual rate.
    var r10: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(dollars(balance)).font(.title3.bold()).monospacedDigit()
                Spacer()
                if let (gain, cost) = unrealized(positions) {
                    VStack(alignment: .trailing) {
                        Text(signedDollars(gain)).monospacedDigit()
                        if cost > 0 { Text(signedPercent(gain / cost)).font(.caption).monospacedDigit() }
                    }
                    .foregroundStyle(gain >= 0 ? Color.green : Color.red)
                }
            }
            if let m = overBaseline(positions) {
                // r: what the same dollars made in the baseline, and the
                // gain over it.
                HStack(alignment: .firstTextBaseline) {
                    Text("\(baseline) would have made \(signedDollars(m.baseline))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer()
                    Text(againstR(m.gain - m.baseline, rate: rates.0, base: rates.1)).monospacedDigit()
                        .foregroundStyle(m.gain - m.baseline >= 0 ? Color.green : Color.red)
                }
                .font(.caption)
                if let t = overR10(positions) {
                    // r10: the 10-year yield locked in on each buy day.
                    HStack(alignment: .firstTextBaseline) {
                        Text("10-year Treasuries would have made \(signedDollars(t.r10))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Spacer()
                        Text(againstR10(t.gain - t.r10, rate: rates.0, base: r10)).monospacedDigit()
                            .foregroundStyle(t.gain - t.r10 >= 0 ? Color.green : Color.red)
                    }
                    .font(.caption)
                }
                if let k = overMarket(positions) {
                    // The market: what the same dollars made in the S&P 500.
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(market) would have made \(signedDollars(k.market))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Spacer()
                        Text(againstMarket(k.gain - k.market, rate: rates.0, base: rates.2)).monospacedDigit()
                            .foregroundStyle(k.gain - k.market >= 0 ? Color.green : Color.red)
                    }
                    .font(.caption)
                }
                Text("Dividends and distributions on all sides, on \(m.measured) of \(m.of) positions: the ones whose buys are all on record (Plaid's two years, and the brokerage's reports before them). Points a year: the premium of your annual rate (XIRR) over theirs, on positions held a year or more.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PositionRow: View {
    let position: Equities_V1_Position

    private var note: String {
        switch position.kind {
        case .short: return "short \(abs(position.quantity).formatted())"
        case .option: return "option, value only"
        case .cash: return position.value < 0 ? "margin debit" : "cash"
        default: return position.quantity.formatted(.number.precision(.fractionLength(0...4))) + " @ " + dollars(position.price)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(position.ticker.isEmpty ? position.name : position.ticker).font(.body.bold())
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(dollars(position.value)).monospacedDigit()
                if let (gain, cost) = unrealized([position]) {
                    Text(signedDollars(gain) + (cost > 0 ? "  " + signedPercent(gain / cost) : ""))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(gain >= 0 ? Color.green : Color.red)
                }
                if let m = overBaseline([position]) {
                    Text(againstR(m.gain - m.baseline, rate: position.annualRate, base: position.baselineRate))
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(m.gain - m.baseline >= 0 ? Color.green : Color.red)
                }
                if let t = overR10([position]) {
                    Text(againstR10(t.gain - t.r10, rate: position.annualRate, base: position.r10Rate))
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(t.gain - t.r10 >= 0 ? Color.green : Color.red)
                }
                if let k = overMarket([position]) {
                    Text(againstMarket(k.gain - k.market, rate: position.annualRate, base: position.marketRate))
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(k.gain - k.market >= 0 ? Color.green : Color.red)
                }
            }
        }
    }
}

// Optional proto fields as Swift optionals: the annual rates (XIRR), set
// only when solvable over a year or more.
extension Equities_V1_Position {
    var annualRate: Double? { hasAnnualReturn ? annualReturn : nil }
    var baselineRate: Double? { hasBaselineAnnual ? baselineAnnual : nil }
    var marketRate: Double? { hasMarketAnnual ? marketAnnual : nil }
    var r10Rate: Double? { hasR10Annual ? r10Annual : nil }
}
extension Equities_V1_Account {
    var annualRate: Double? { hasAnnualReturn ? annualReturn : nil }
    var baselineRate: Double? { hasBaselineAnnual ? baselineAnnual : nil }
    var marketRate: Double? { hasMarketAnnual ? marketAnnual : nil }
    var r10Rate: Double? { hasR10Annual ? r10Annual : nil }
}
extension Equities_V1_HoldingsResponse {
    var annualRate: Double? { hasAnnualReturn ? annualReturn : nil }
    var baselineRate: Double? { hasBaselineAnnual ? baselineAnnual : nil }
    var marketRate: Double? { hasMarketAnnual ? marketAnnual : nil }
    var r10Rate: Double? { hasR10Annual ? r10Annual : nil }
}
