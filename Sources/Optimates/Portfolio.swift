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
                    Totals(positions: reply.accounts.flatMap(\.positions), balance: reply.accounts.map(\.balance).reduce(0, +), baseline: reply.baseline)
                } footer: {
                    if reply.syncedUnix > 0 {
                        Text("Synced with the brokerage \(Date(timeIntervalSince1970: TimeInterval(reply.syncedUnix)).formatted(.relative(presentation: .named))). Pull to refresh.")
                    }
                }
                ForEach(reply.accounts, id: \.name) { account in
                    Section {
                        Totals(positions: account.positions, balance: account.balance, baseline: reply.baseline)
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
            let fresh = try await API.current().call(.holdings, request)
            ReplyCache.shared.put("holdings", fresh)
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
/// their gain, what the same dollars made in the baseline over the same
/// days, and how many of the long positions that covers (buys older than
/// Plaid's two years can't be measured).
func overBaseline(_ positions: [Equities_V1_Position]) -> (gain: Double, baseline: Double, measured: Int, of: Int)? {
    let longs = positions.filter { $0.kind == .long }
    let measured = longs.filter { $0.hasCost && $0.hasBaselineCost && $0.hasBaselineValue }
    guard !measured.isEmpty else { return nil }
    return (measured.map { $0.value - $0.cost }.reduce(0, +),
            measured.map { $0.baselineValue - $0.baselineCost }.reduce(0, +),
            measured.count, longs.count)
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
                    Spacer()
                    Text("over r " + signedDollars(m.gain - m.baseline)).monospacedDigit()
                        .foregroundStyle(m.gain - m.baseline >= 0 ? Color.green : Color.red)
                }
                .font(.caption)
                Text("on \(m.measured) of \(m.of) positions: the ones whose buys are all in the last two years")
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
                    Text("over r " + signedDollars(m.gain - m.baseline))
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(m.gain - m.baseline >= 0 ? Color.green : Color.red)
                }
            }
        }
    }
}
