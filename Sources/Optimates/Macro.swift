import Foundation
import SwiftUI

// What the macro panels compute from FRED's series: inflation over a year,
// the output gap, the Taylor rule. The API serves the series as published;
// the arithmetic is here, with its tests.

private let utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// Percent change over twelve months, for an index (CPI, PCE): each point
/// against the one a year before it, where there is one.
func yearOverYear(_ points: [Point]) -> [Point] {
    let byDate = Dictionary(points.map { ($0.time, $0.value) }, uniquingKeysWith: { a, _ in a })
    return points.compactMap { p in
        guard let earlier = utcCalendar.date(byAdding: .year, value: -1, to: p.time),
              let before = byDate[earlier], before != 0 else { return nil }
        return Point(time: p.time, value: 100 * (p.value / before - 1))
    }
}

/// `actual` against `potential`, in percent of potential, where both have
/// the date: the output gap, from real GDP and CBO's potential.
func percentGap(_ actual: [Point], _ potential: [Point]) -> [Point] {
    let byDate = Dictionary(potential.map { ($0.time, $0.value) }, uniquingKeysWith: { a, _ in a })
    return actual.compactMap { p in
        guard let pot = byDate[p.time], pot != 0 else { return nil }
        return Point(time: p.time, value: 100 * (p.value / pot - 1))
    }
}

/// `a - b` at `a`'s dates, `b` read as of each (its last value on or
/// before): unemployment against its natural rate.
func difference(_ a: [Point], _ b: [Point]) -> [Point] {
    let other = Series(name: "", points: b)
    return a.compactMap { p in other.value(at: p.time).map { Point(time: p.time, value: p.value - $0) } }
}

/// Taylor's rule (1993): i = r* + π + ½(π − π*) + ½·gap, at the inflation
/// series' dates, the gap read as of each. Taylor's own r* was 2 and π* 2.
func taylorRule(inflation: [Point], gap: [Point], rStar: Double, target: Double = 2) -> [Point] {
    taylorRule(inflation: inflation, gap: gap, rStar: inflation.map { Point(time: $0.time, value: rStar) }, target: target)
}

/// The same with r* changing over time (the New York Fed's estimates, read
/// as of each date): Taylor's rule as the Fed's own staff would write it now.
func taylorRule(inflation: [Point], gap: [Point], rStar: [Point], target: Double = 2) -> [Point] {
    let g = Series(name: "", points: gap), r = Series(name: "", points: rStar)
    return inflation.compactMap { p in
        guard let gap = g.value(at: p.time), let rStar = r.value(at: p.time) else { return nil }
        return Point(time: p.time, value: rStar + p.value + 0.5 * (p.value - target) + 0.5 * gap)
    }
}

/// A chart of a FRED screen: its title, its lines, how its axis reads.
struct FREDPanel {
    let title: String
    let lines: [Series]
    var format: Format = .points
}

/// A screen of FRED series (the API's Macro): it fetches `series`, keeps the
/// reply on the device, and draws `panels` of what came back, with the
/// dashboards' charts, crosshair and date range.
struct FREDScreen: View {
    let title: String
    /// Where the reply is kept on the device.
    let cacheKey: String
    let series: [String]
    /// Who publishes the data, for the footnote.
    let source: String
    /// Charts of the screen's own, above its panels, once data is in.
    var header: ((_ data: [String: [Point]]) -> AnyView)? = nil
    let panels: (_ data: [String: [Point]]) -> [FREDPanel]

    @State private var data: [String: [Point]]?
    @State private var keptFrom: Date?
    @State private var notUpdated: String?
    @State private var error: String?
    @State private var selected: Date?
    @AppStorage(Pins.defaultsKey) private var pins = Pins.initial
    // The same range as the dashboards.
    @AppStorage("range") private var range = DateRange.all
    @AppStorage("rangeFrom") private var rangeFrom = Date().addingTimeInterval(-10 * 365.25 * 86_400).timeIntervalSince1970
    @AppStorage("rangeTo") private var rangeTo = Date().timeIntervalSince1970

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Dates", selection: $range) {
                    ForEach(DateRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                if let keptFrom {
                    Text("Saved \(keptFrom.formatted(.relative(presentation: .named)))" + (notUpdated.map { ": not updated, " + $0 } ?? ", updating…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let header, let data {
                    header(data)
                }
                ForEach(panels(data ?? [:]), id: \.title) { panel in
                    Panel(title: panel.title, series: panel.lines, loading: data == nil && error == nil,
                          format: panel.format,
                          range: range.dates(from: Date(timeIntervalSince1970: rangeFrom), to: Date(timeIntervalSince1970: rangeTo)),
                          selected: $selected)
                }
                Text("FRED (St. Louis Fed): \(source).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(title)
        .toolbar { PinButton(key: cacheKey, pins: $pins) }
        .task {
            if data == nil, let (kept, fetched) = ReplyCache.shared.get(Equities_V1_MacroResponse.self, cacheKey) {
                data = macroData(kept)
                keptFrom = fetched
            }
            var request = Equities_V1_MacroRequest()
            request.series = series
            do {
                let reply = try await ReplyCache.shared.fetch(cacheKey, .macro, request)
                data = macroData(reply)
                (keptFrom, notUpdated) = (nil, nil)
            } catch where isCancellation(error) {
            } catch {
                if data == nil { self.error = describe(error) } else { notUpdated = describe(error) }
            }
        }
    }
}

/// π and r: inflation, the policy rate against Taylor's rule, nominal and
/// real rates, and the gaps.
struct MacroView: View {
    /// The sidebar's tag for this screen.
    static let tag = "★ macro"

    var body: some View {
        FREDScreen(title: "π and r", cacheKey: "macro",
                   series: ["PCEPILFE", "PCEPI", "CPIAUCSL", "EXPINF1YR", "MICH",
                            "FEDFUNDS", "GS10", "FII10", "T10YIEM",
                            "GDPC1", "GDPPOT", "UNRATE", "NROU",
                            "HLW_RSTAR_US", "HLW_RSTAR_CA", "HLW_RSTAR_EA"],
                   source: "BEA, BLS, CBO, the Fed, the Cleveland Fed, the University of Michigan; r*, the New York Fed (Holston, Laubach and Williams)") { d in
            let s = { (id: String) in d[id] ?? [] }
            let corePCE = yearOverYear(s("PCEPILFE"))
            let gap = percentGap(s("GDPC1"), s("GDPPOT"))
            return [
                FREDPanel(title: "inflation, over a year (%)", lines: [
                    Series(name: "core PCE", points: corePCE),
                    Series(name: "PCE", points: yearOverYear(s("PCEPI"))),
                    Series(name: "CPI", points: yearOverYear(s("CPIAUCSL"))),
                    Series(name: "expected, 1 year (Cleveland Fed)", points: s("EXPINF1YR")),
                    Series(name: "expected, households (Michigan)", points: s("MICH")),
                ]),
                FREDPanel(title: "the policy rate and Taylor's rule (%)", lines: [
                    Series(name: "fed funds", points: s("FEDFUNDS")),
                    Series(name: "Taylor, r* 2 (1993)", points: taylorRule(inflation: corePCE, gap: gap, rStar: 2)),
                    Series(name: "Taylor, r* 0.5", points: taylorRule(inflation: corePCE, gap: gap, rStar: 0.5)),
                    Series(name: "Taylor, r* the New York Fed's", points: taylorRule(inflation: corePCE, gap: gap, rStar: s("HLW_RSTAR_US"))),
                ]),
                // Wicksell's two rates: the natural one, and the market's.
                FREDPanel(title: "r*, the natural rate, and the real rates (%)", lines: [
                    Series(name: "r*, US", points: s("HLW_RSTAR_US")),
                    Series(name: "r*, Canada", points: s("HLW_RSTAR_CA")),
                    Series(name: "r*, euro area", points: s("HLW_RSTAR_EA")),
                    Series(name: "real fed funds (less core PCE)", points: difference(s("FEDFUNDS"), corePCE)),
                    Series(name: "10-year TIPS", points: s("FII10")),
                ]),
                FREDPanel(title: "10 years: nominal, real, expected inflation (%)", lines: [
                    Series(name: "Treasury", points: s("GS10")),
                    Series(name: "TIPS (real)", points: s("FII10")),
                    Series(name: "breakeven inflation", points: s("T10YIEM")),
                ]),
                FREDPanel(title: "the gaps (percentage points)", lines: [
                    Series(name: "output gap (GDP vs CBO potential, %)", points: gap),
                    Series(name: "unemployment vs its natural rate", points: difference(s("UNRATE"), s("NROU"))),
                ]),
            ]
        }
    }
}

/// A Macro reply by series ID, its days as dates.
func macroData(_ reply: Equities_V1_MacroResponse) -> [String: [Point]] {
    Dictionary(reply.series.map { s in
        (s.id, s.points.map { Point(time: Date(timeIntervalSince1970: TimeInterval($0.epochDay) * 86_400), value: $0.value) })
    }, uniquingKeysWith: { a, _ in a })
}
