import Foundation
import SwiftData
import SwiftProtobuf
import XCTest
@testable import Optimates

/// The wire format, byte for byte, as the API (Rust, prost) writes it: the
/// same hex is in lib's equities/api/src/rpc.rs (tests::golden_bytes). If one
/// side's code from the .proto changes how a message is written, both fail.
final class ContractTests: XCTestCase {
    // ticker "gs", items [TotalAssets], periods [Quarter], market [Close, MarketCap]
    static let goldenRequest = "0a026773 120116 1a0101 22020102"
    // TotalAssets at a point in time in USD, 2026-03-31: 1.5e12; market cap in
    // JPY, 1970-01-01: -2 and 1970-01-02: 0.25
    static let goldenResponse = "0a1a0a04081610051a03555344220d08bfa0011100008079efd37542 0a1f10021a034a505922091100000000000000c0220b080111000000000000d03f"

    func testRequestIsWhatTheServerReads() throws {
        // As the dashboard builds it: lines in any order, items and fields once.
        let request = dashboardRequest("gs", sources: [
            .market(.marketCap), .reported(.totalAssets, .quarter), .market(.close), .reported(.totalAssets, .year),
        ], periods: [.quarter])
        XCTAssertEqual(hex(try request.serializedData()), Self.goldenRequest.replacingOccurrences(of: " ", with: ""))
    }

    func testResponseIsReadAsTheServerWrites() throws {
        let response = try Equities_V1_DashboardResponse(serializedBytes: bytes(Self.goldenResponse))
        let data = companyData(response)
        XCTAssertEqual(Set(data.keys), ["USD", "JPY"])

        let assets = try XCTUnwrap(data["USD"]?[.reported(.totalAssets, .pointInTime)])
        XCTAssertEqual(assets.map(\.value), [1.5e12])
        XCTAssertEqual(assets[0].time, utc(2026, 3, 31))

        let cap = try XCTUnwrap(data["JPY"]?[.market(.marketCap)])
        XCTAssertEqual(cap.map(\.value), [-2, 0.25])
        XCTAssertEqual(cap.map(\.time), [utc(1970, 1, 1), utc(1970, 1, 2)])
    }

    /// A kind of series a newer API might send is skipped, not misread.
    func testUnknownSeriesIsSkipped() {
        var series = Equities_V1_Series()
        series.currency = "USD"
        series.points = [Equities_V1_Point.with { $0.epochDay = 1; $0.value = 1 }]
        var response = Equities_V1_DashboardResponse()
        response.series = [series]
        XCTAssertTrue(companyData(response).isEmpty)
    }
}

/// What the crosshair reads.
final class CrosshairTests: XCTestCase {
    let quarters = Series(name: "revenue", points: [
        Point(time: utc(2025, 3, 31), value: 1),
        Point(time: utc(2025, 6, 30), value: 2),
    ])

    func testLastPointOnOrBefore() {
        XCTAssertNil(quarters.value(at: utc(2025, 3, 30)))
        XCTAssertEqual(quarters.value(at: utc(2025, 3, 31)), 1)
        XCTAssertEqual(quarters.value(at: utc(2025, 6, 29)), 1)
        XCTAssertEqual(quarters.value(at: utc(2025, 6, 30)), 2)
    }

    func testNothingOverAYearAfterTheLast() {
        XCTAssertEqual(quarters.value(at: utc(2026, 6, 30)), 2)
        XCTAssertNil(quarters.value(at: utc(2026, 8, 30)))
    }
}

final class DateRangeTests: XCTestCase {
    let now = utc(2026, 11, 25)

    func testPresetsEndToday() {
        XCTAssertEqual(DateRange.year.dates(from: now, to: now, now: now), utc(2025, 11, 25) ... now)
        XCTAssertEqual(DateRange.tenYears.dates(from: now, to: now, now: now)?.lowerBound, utc(2016, 11, 25))
        XCTAssertNil(DateRange.all.dates(from: now, to: now, now: now))
    }

    func testCustomInEitherOrder() {
        let a = utc(2008, 9, 15), b = utc(2009, 3, 9)
        XCTAssertEqual(DateRange.custom.dates(from: a, to: b, now: now), a ... b)
        XCTAssertEqual(DateRange.custom.dates(from: b, to: a, now: now), a ... b)
    }
}

/// The device's cache of replies, in memory.
@MainActor
final class ReplyCacheTests: XCTestCase {
    func cache(limit: Int = 40) throws -> ReplyCache {
        ReplyCache(container: try ModelContainer(for: CachedReply.self,
                                                 configurations: ModelConfiguration(isStoredInMemoryOnly: true)),
                   limit: limit)
    }

    func tickers(_ t: String...) -> Equities_V1_TickersResponse { .with { $0.tickers = t } }

    func testKeepsTheReplyAsSent() throws {
        let cache = try cache()
        let at = utc(2026, 11, 25)
        cache.put("tickers", tickers("AAPL", "GS"), fetched: at)
        let (kept, fetched) = try XCTUnwrap(cache.get(Equities_V1_TickersResponse.self, "tickers"))
        XCTAssertEqual(kept.tickers, ["AAPL", "GS"])
        XCTAssertEqual(fetched, at)

        cache.put("tickers", tickers("NVDA"))
        XCTAssertEqual(cache.get(Equities_V1_TickersResponse.self, "tickers")?.0.tickers, ["NVDA"])
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache.get(Equities_V1_TickersResponse.self, "dashboard/GS"))
    }

    func testKeepsTheMostRecentlyUsed() throws {
        let cache = try cache(limit: 2)
        cache.put("a", tickers("A"), fetched: utc(2026, 1, 1))
        cache.put("b", tickers("B"), fetched: utc(2026, 1, 2))
        _ = cache.get(Equities_V1_TickersResponse.self, "a")   // a is now the most recent
        cache.put("c", tickers("C"))
        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.get(Equities_V1_TickersResponse.self, "a"))
        XCTAssertNil(cache.get(Equities_V1_TickersResponse.self, "b"))
        XCTAssertNotNil(cache.get(Equities_V1_TickersResponse.self, "c"))
    }

    func testClear() throws {
        let cache = try cache()
        cache.put("tickers", tickers("AAPL"))
        cache.clear()
        XCTAssertEqual(cache.count, 0)
    }
}

final class PortfolioTests: XCTestCase {
    func position(_ kind: Equities_V1_PositionKind, value: Double, cost: Double?) -> Equities_V1_Position {
        .with { p in p.kind = kind; p.value = value; if let cost { p.cost = cost } }
    }

    func testGainCountsSharesAndShortsWithACost() throws {
        let (gain, cost) = try XCTUnwrap(unrealized([
            position(.long, value: 120, cost: 100),    // +20
            position(.short, value: -40, cost: -50),   // shorted at 50, now 40: +10
            position(.long, value: 50, cost: nil),     // no cost: left out
            position(.option, value: -1_000, cost: nil), // options: value only
            position(.cash, value: -500, cost: nil),
        ]))
        XCTAssertEqual(gain, 30, accuracy: 1e-9)
        XCTAssertEqual(cost, 150, accuracy: 1e-9)
    }

    func testNoGainWithoutACost() {
        XCTAssertNil(unrealized([position(.option, value: 900, cost: 1_200)]))
    }
}

final class ErrorTests: XCTestCase {
    func testCancellationsAreNotErrors() {
        XCTAssertTrue(isCancellation(CancellationError()))
        XCTAssertTrue(isCancellation(URLError(.cancelled)))
        XCTAssertFalse(isCancellation(URLError(.timedOut)))
        XCTAssertFalse(isCancellation(APIError.signIn))
    }
}

func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func bytes(_ hex: String) -> Data {
    let digits = Array(hex.replacingOccurrences(of: " ", with: ""))
    return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
}

/// The macro panels' arithmetic.
final class MacroTests: XCTestCase {
    func p(_ y: Int, _ m: Int, _ v: Double) -> Point { Point(time: utc(y, m, 1), value: v) }

    func testYearOverYear() {
        let index = [p(2025, 1, 100), p(2025, 2, 101), p(2026, 1, 103), p(2026, 2, 102.01)]
        let yoy = yearOverYear(index)
        XCTAssertEqual(yoy.map(\.time), [utc(2026, 1, 1), utc(2026, 2, 1)])
        XCTAssertEqual(yoy[0].value, 3, accuracy: 1e-9)
        XCTAssertEqual(yoy[1].value, 1, accuracy: 1e-9)
    }

    func testOutputGap() {
        let gap = percentGap([p(2026, 7, 102), p(2026, 10, 99)], [p(2026, 7, 100), p(2026, 10, 100)])
        XCTAssertEqual(gap[0].value, 2, accuracy: 1e-9)
        XCTAssertEqual(gap[1].value, -1, accuracy: 1e-9)
    }

    func testTaylor1993() {
        // π 3, gap 1 (the latest quarter's, for each month): 2 + 3 + ½·1 + ½·1 = 6.
        let rule = taylorRule(inflation: [p(2026, 8, 3), p(2026, 9, 3)], gap: [p(2026, 7, 1)], rStar: 2)
        XCTAssertEqual(rule.map(\.value), [6, 6])
        // Before any gap: no rule.
        XCTAssertTrue(taylorRule(inflation: [p(2026, 6, 3)], gap: [p(2026, 7, 1)], rStar: 2).isEmpty)
    }

    func testTaylorWithAChangingRStar() {
        // π 3, gap 1: with r* 2 from July, 0.5 from September: 6, then 4.5.
        let rule = taylorRule(inflation: [p(2026, 8, 3), p(2026, 9, 3)], gap: [p(2026, 7, 1)],
                              rStar: [p(2026, 7, 2), p(2026, 9, 0.5)])
        XCTAssertEqual(rule.map(\.value), [6, 4.5])
    }

    func testUnemploymentGap() {
        let gap = difference([p(2026, 9, 4.1), p(2026, 10, 4.3)], [p(2026, 7, 4.2)])
        // Unemployment against CBO's natural rate, read as of each month.
        XCTAssertEqual(gap[0].value, -0.1, accuracy: 1e-9)
        XCTAssertEqual(gap[1].value, 0.1, accuracy: 1e-9)
    }
}

/// The portfolio against its r.
final class BaselineTests: XCTestCase {
    func long(value: Double, cost: Double, baselineCost: Double?, baselineValue: Double?, dividends: Double? = nil) -> Equities_V1_Position {
        .with { p in
            p.kind = .long; p.value = value; p.cost = cost
            if let baselineCost { p.baselineCost = baselineCost }
            if let baselineValue { p.baselineValue = baselineValue }
            if let dividends { p.dividends = dividends }
        }
    }

    func testDividendsAndTheBrokeragesCost() throws {
        // Shares bought for $1,000 by exercising a call that cost $500: the
        // brokerage's cost is $1,500. Worth $1,450 now, with $50 of dividends:
        // return 0. MINT grew 4% over the buys' days: on $1,500, +$60.
        let m = try XCTUnwrap(overBaseline([long(value: 1_450, cost: 1_500, baselineCost: 1_000, baselineValue: 1_040, dividends: 50)]))
        XCTAssertEqual(m.gain, 0, accuracy: 1e-9)
        XCTAssertEqual(m.baseline, 60, accuracy: 1e-9)
        XCTAssertEqual(againstR(m.gain - m.baseline), "under r -$60.00")
        XCTAssertEqual(againstR(12), "over r +$12.00")
    }

    func testOverBaselineCountsOnlyMeasuredLongs() throws {
        let m = try XCTUnwrap(overBaseline([
            long(value: 120, cost: 100, baselineCost: 100, baselineValue: 104),  // +20, MINT +4
            long(value: 90, cost: 100, baselineCost: 100, baselineValue: 103),   // -10, MINT +3
            long(value: 50, cost: 40, baselineCost: nil, baselineValue: nil),    // not measured
            .with { $0.kind = .short; $0.value = -10; $0.cost = -12 },          // shorts: no baseline
        ]))
        XCTAssertEqual(m.gain, 10, accuracy: 1e-9)
        XCTAssertEqual(m.baseline, 7, accuracy: 1e-9)
        XCTAssertEqual(m.measured, 2)
        XCTAssertEqual(m.of, 3)
    }
}

/// The portfolio against the market.
final class MarketTests: XCTestCase {
    func testOverMarketOnTheSameDollars() throws {
        // Return +$20 on $100; the same dollars made +$4 in MINT and +$25 in
        // the S&P 500: over r, under market.
        let p = Equities_V1_Position.with {
            $0.kind = .long; $0.value = 118; $0.cost = 100; $0.dividends = 2
            $0.baselineCost = 100; $0.baselineValue = 104; $0.marketValue = 125
        }
        let r = try XCTUnwrap(overBaseline([p]))
        let k = try XCTUnwrap(overMarket([p]))
        XCTAssertEqual(r.gain - r.baseline, 16, accuracy: 1e-9)
        XCTAssertEqual(k.gain - k.market, -5, accuracy: 1e-9)
        XCTAssertEqual(againstMarket(k.gain - k.market), "under market -$5.00")
        // No market value: not measured against it.
        XCTAssertNil(overMarket([.with { $0.kind = .long; $0.value = 1; $0.cost = 1; $0.baselineCost = 1 }]))
    }
}

/// The real-estate panels' arithmetic.
final class RealEstateTests: XCTestCase {
    func p(_ y: Int, _ m: Int, _ v: Double) -> Point { Point(time: utc(y, m, 1), value: v) }

    func testMonthlyPayment() {
        // $100,000 at 6% for 30 years: the textbook $599.55.
        XCTAssertEqual(monthlyPayment(principal: 100_000, annualRate: 6), 599.55, accuracy: 0.01)
        // At 0%, principal over the months.
        XCTAssertEqual(monthlyPayment(principal: 36_000, annualRate: 0), 100, accuracy: 1e-9)
    }

    func testMedianPaymentUsesTheRateOfTheDay() {
        // A $250,000 house, 20% down, at 6% then 7%.
        let pay = medianPayment(prices: [p(2026, 1, 250_000), p(2026, 4, 250_000)],
                                rates: [p(2025, 12, 6), p(2026, 3, 7)])
        XCTAssertEqual(pay[0].value, monthlyPayment(principal: 200_000, annualRate: 6), accuracy: 1e-9)
        XCTAssertEqual(pay[1].value, monthlyPayment(principal: 200_000, annualRate: 7), accuracy: 1e-9)
    }

    func testPriceToRent() {
        // Prices double while rents rise half as much: the ratio rises a third.
        let r = ratioIndex([p(2020, 1, 100), p(2025, 1, 200)], [p(2020, 1, 50), p(2025, 1, 75)])
        XCTAssertEqual(r[0].value, 100, accuracy: 1e-9)
        XCTAssertEqual(r[1].value, 100 * (200.0 / 75) / (100.0 / 50), accuracy: 1e-9)
    }
}
