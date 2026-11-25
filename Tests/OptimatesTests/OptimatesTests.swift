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
