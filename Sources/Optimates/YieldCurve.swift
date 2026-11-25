import Charts
import Foundation
import SwiftUI

/// The Treasury yield curve by month: the constant-maturity yields FRED
/// keeps monthly (the 3-month bill, then 1, 2, 5, 10 and 30 years), for the
/// months that have all of them (February 1977 on, the 30-year's start).
struct YieldCurve: Equatable {
    /// FRED's series, the maturity in years, and its label.
    static let maturities: [(id: String, years: Double, label: String)] = [
        ("TB3MS", 0.25, "3m"), ("GS1", 1, "1y"), ("GS2", 2, "2y"),
        ("GS5", 5, "5y"), ("GS10", 10, "10y"), ("GS30", 30, "30y"),
    ]

    /// The months, oldest first, each as a fractional year (computed once:
    /// the surface asks for the nearest month thousands of times a draw), and
    /// each month's yields, by maturity.
    let months: [Date]
    let years: [Double]
    let yields: [[Double]]

    init(_ data: [String: [Point]]) {
        let byID = Self.maturities.map { m in
            Dictionary((data[m.id] ?? []).map { ($0.time, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        let common = byID.dropFirst().reduce(Set(byID.first?.keys ?? [:].keys)) { $0.intersection($1.keys) }
        months = common.sorted()
        years = months.map(Self.year)
        yields = months.map { month in byID.map { $0[month]! } }
    }

    var isEmpty: Bool { months.isEmpty }

    /// A month as a fractional year: 2026.83.
    static func year(_ date: Date) -> Double {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        return Double(c.year!) + Double(c.month! - 1) / 12
    }

    var firstYear: Double { years.first ?? 0 }
    var lastYear: Double { years.last ?? 0 }

    /// The month nearest a fractional year, by binary search: the months
    /// aren't contiguous (no 30-year yields 2002–2006, so no full curve then).
    func month(nearest year: Double) -> Int {
        guard !years.isEmpty else { return 0 }
        let i = years.partitionPoint { $0 < year }
        if i == 0 { return 0 }
        if i == years.count { return years.count - 1 }
        return year - years[i - 1] <= years[i] - year ? i - 1 : i
    }

    /// The yield at a maturity position: 0 the 3-month, 5 the 30-year,
    /// linear between neighbours (the surface spaces maturities evenly, so
    /// the short end isn't squeezed into a sliver).
    func yield(position: Double, month: Int) -> Double {
        let row = yields[month]
        let x = min(max(position, 0), Double(row.count - 1))
        let i = min(Int(x), row.count - 2)
        let f = x - Double(i)
        return row[i] * (1 - f) + row[i + 1] * f
    }

    /// The curve at the month nearest `date`: (label, yield) by maturity.
    func curve(near date: Date) -> (month: Date, points: [(label: String, yield: Double)])? {
        guard !months.isEmpty else { return nil }
        let m = month(nearest: Self.year(date))
        return (months[m], zip(Self.maturities, yields[m]).map { ($0.label, $1) })
    }
}

/// The yield curve: as a surface (iOS 26), at five dates, and the spread
/// between its ends over time.
struct YieldCurveView: View {
    static let tag = "★ yield curve"

    var body: some View {
        FREDScreen(title: "Yield curve", cacheKey: "yieldcurve",
                   series: YieldCurve.maturities.map(\.id),
                   source: "the Federal Reserve Board (H.15)",
                   header: { data in AnyView(YieldCurveCharts(curve: YieldCurve(data)).equatable()) }) { d in
            [FREDPanel(title: "10-year less 3-month (percentage points; below zero, inverted)", lines: [
                Series(name: "10-year less 3-month", points: difference(d["GS10"] ?? [], d["TB3MS"] ?? [])),
            ])]
        }
    }
}

/// The surface and the curves, above the screen's panels.
/// Equatable, and compared (`.equatable()` where it's made): the screen
/// redraws whenever its state changes (the crosshair, the range), and the
/// surface is the expensive part, so it's drawn again only when the curve
/// itself is different.
private struct YieldCurveCharts: View, Equatable {
    let curve: YieldCurve

    /// The dates the curves are drawn at: now, a year and five years before,
    /// the eve of 2008, and the Volcker peak.
    private var dates: [(name: String, date: Date)] {
        guard let last = curve.months.last else { return [] }
        let cal = Calendar(identifier: .gregorian)
        return [
            ("latest", last),
            ("a year before", cal.date(byAdding: .year, value: -1, to: last)!),
            ("five years before", cal.date(byAdding: .year, value: -5, to: last)!),
            ("before the crisis", utcDate(2007, 6)),
            ("the Volcker peak", utcDate(1981, 9)),
        ]
    }

    /// "Jun 2007": FRED's months are the 1st at midnight UTC, which local
    /// time west of Greenwich would call the month before.
    private func monthLabel(_ month: Date) -> String {
        month.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).year().month(.abbreviated))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            #if compiler(>=6.2)
            if #available(iOS 26, macOS 26, *), !curve.isEmpty {
                VStack(alignment: .leading) {
                    Text("the curve since \(Int(curve.firstYear)), as a surface").font(.headline)
                    YieldSurface(curve: curve)
                    Text("Maturity across (3m, 1y, 2y, 5y, 10y, 30y, evenly spaced), years in depth, yield up. Drag to turn it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            #endif
            VStack(alignment: .leading) {
                Text("the curve at five dates (%)").font(.headline)
                Chart {
                    ForEach(dates, id: \.name) { d in
                        if let c = curve.curve(near: d.date) {
                            ForEach(c.points, id: \.label) { p in
                                LineMark(x: .value("Maturity", p.label), y: .value("Yield", p.yield))
                                    .foregroundStyle(by: .value("Date", "\(d.name), \(monthLabel(c.month))"))
                                PointMark(x: .value("Maturity", p.label), y: .value("Yield", p.yield))
                                    .foregroundStyle(by: .value("Date", "\(d.name), \(monthLabel(c.month))"))
                            }
                        }
                    }
                }
                .chartXScale(domain: YieldCurve.maturities.map(\.label))
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text(Format.points.label(v)) } }
                    }
                }
                .frame(height: 260)
            }
        }
    }
}

private func utcDate(_ year: Int, _ month: Int) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: year, month: month, day: 1))!
}

#if compiler(>=6.2)
/// The curve as a surface: Swift Charts' 3D (iOS 26), built only by Xcode
/// Cloud's compiler; the Mac's can't, so it's first seen on the phone.
@available(iOS 26, macOS 26, *)
private struct YieldSurface: View {
    let curve: YieldCurve
    @State private var pose: Chart3DPose = .default

    var body: some View {
        Chart3D {
            SurfacePlot(x: "Maturity", y: "Yield", z: "Year") { x, z in
                curve.yield(position: x, month: curve.month(nearest: z))
            }
        }
        .chartXScale(domain: 0...Double(YieldCurve.maturities.count - 1))
        .chartYScale(domain: 0...16)
        .chartZScale(domain: curve.firstYear...curve.lastYear)
        .chart3DPose($pose)
        .frame(height: 360)
    }
}
#endif

extension Array {
    /// The first index whose element doesn't satisfy `belongsBefore`, for an
    /// array ordered so that those that do all come first.
    func partitionPoint(_ belongsBefore: (Element) -> Bool) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let mid = (low + high) / 2
            if belongsBefore(self[mid]) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
