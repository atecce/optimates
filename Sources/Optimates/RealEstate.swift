import Foundation
import SwiftUI

// Real estate and the mortgage market, from FRED (fred/realestate.txt in
// lib): what a house costs, what it costs to borrow for one, what it would
// rent for, how much is built and sold, and how the debt is doing.

/// `a / b` at `a`'s dates (`b` read as of each), scaled to 100 at the first:
/// price to rent, from a house price index and a rent index.
func ratioIndex(_ a: [Point], _ b: [Point]) -> [Point] {
    let other = Series(name: "", points: b)
    let ratios = a.compactMap { p in other.value(at: p.time).flatMap { $0 == 0 ? nil : Point(time: p.time, value: p.value / $0) } }
    guard let first = ratios.first?.value, first != 0 else { return [] }
    return ratios.map { Point(time: $0.time, value: 100 * $0.value / first) }
}

/// The monthly payment on a fixed-rate loan: `principal` at `annualRate`
/// percent, over `months`.
func monthlyPayment(principal: Double, annualRate: Double, months: Int = 360) -> Double {
    let i = annualRate / 100 / 12
    guard i > 0 else { return principal / Double(months) }
    return principal * i / (1 - pow(1 + i, -Double(months)))
}

/// The monthly payment on the median house sold (`prices`, quarterly),
/// borrowing all but `down` of it for 30 years at the mortgage rate of the
/// day (`rates`, read as of each).
func medianPayment(prices: [Point], rates: [Point], down: Double = 0.2) -> [Point] {
    let r = Series(name: "", points: rates)
    return prices.compactMap { p in
        r.value(at: p.time).map { Point(time: p.time, value: monthlyPayment(principal: p.value * (1 - down), annualRate: $0)) }
    }
}

struct RealEstateView: View {
    /// The sidebar's tag for this screen.
    static let tag = "★ real estate"

    var body: some View {
        FREDScreen(title: "Real estate", cacheKey: "realestate",
                   series: ["MORTGAGE30US", "MORTGAGE15US", "GS10",
                            "CSUSHPISA", "CUSR0000SEHA", "CUSR0000SEHC", "MSPUS",
                            "HOUST", "PERMIT", "HSN1F", "MSACSR",
                            "DRSFRMACBS", "TDSP", "RHORUSQ156N", "RRVRUSQ156N"],
                   source: "Freddie Mac, S&P CoreLogic Case-Shiller, the Census Bureau, BLS, the Fed") { d in
            let s = { (id: String) in d[id] ?? [] }
            return [
                FREDPanel(title: "mortgage rates and the 10-year (%)", lines: [
                    Series(name: "30-year fixed", points: s("MORTGAGE30US")),
                    Series(name: "15-year fixed", points: s("MORTGAGE15US")),
                    Series(name: "10-year Treasury", points: s("GS10")),
                    Series(name: "spread, 30-year over 10-year", points: difference(s("MORTGAGE30US"), s("GS10"))),
                ]),
                FREDPanel(title: "house prices and rents, over a year (%)", lines: [
                    Series(name: "house prices (Case-Shiller)", points: yearOverYear(s("CSUSHPISA"))),
                    Series(name: "rent", points: yearOverYear(s("CUSR0000SEHA"))),
                    Series(name: "owners' equivalent rent", points: yearOverYear(s("CUSR0000SEHC"))),
                ]),
                FREDPanel(title: "price to rent (Case-Shiller over CPI rent; 1987 = 100)", lines: [
                    Series(name: "price to rent", points: ratioIndex(s("CSUSHPISA"), s("CUSR0000SEHA"))),
                ], format: .ratio),
                FREDPanel(title: "the monthly payment on the median house sold (20% down, 30 years fixed)", lines: [
                    Series(name: "monthly payment", points: medianPayment(prices: s("MSPUS"), rates: s("MORTGAGE30US"))),
                ], format: .money("USD")),
                FREDPanel(title: "building and selling (thousands a year)", lines: [
                    Series(name: "housing starts", points: s("HOUST")),
                    Series(name: "permits", points: s("PERMIT")),
                    Series(name: "new houses sold", points: s("HSN1F")),
                ], format: .ratio),
                FREDPanel(title: "new houses for sale (months of supply)", lines: [
                    Series(name: "months of supply", points: s("MSACSR")),
                ], format: .ratio),
                FREDPanel(title: "credit: delinquency and debt service (%)", lines: [
                    Series(name: "mortgages delinquent (banks)", points: s("DRSFRMACBS")),
                    Series(name: "debt service, of disposable income", points: s("TDSP")),
                ]),
                FREDPanel(title: "owning and renting (%)", lines: [
                    Series(name: "homeownership", points: s("RHORUSQ156N")),
                    Series(name: "rental vacancy", points: s("RRVRUSQ156N")),
                ]),
            ]
        }
    }
}
