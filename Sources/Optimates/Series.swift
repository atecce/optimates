import Foundation

/// A value at a date.
struct Point: Decodable {
    let time: Date
    let value: Double

    private enum CodingKeys: String, CodingKey { case date, value }

    /// Dates come as `2026-09-26`, a day: midnight UTC.
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let date = try c.decode(String.self, forKey: .date)
        guard let time = Point.day.date(from: date) else {
            throw DecodingError.dataCorruptedError(forKey: .date, in: c, debugDescription: "not a date: \(date)")
        }
        self.time = time
        value = try c.decode(Double.self, forKey: .value)
    }
}

/// A named line on a chart.
struct Series: Identifiable {
    let name: String
    let points: [Point]
    var id: String { name }
}

/// What a chart line draws.
enum Source {
    /// A reported item: `item` as in `equities::Item`, `period` 3m, 12m or pit.
    case reported(item: String, period: String)
    /// A market field: close, market_cap, price_to_book, return_on_equity,
    /// earnings_yield.
    case market(field: String)

    /// Its place in a company's `Dashboard` data.
    var key: String {
        switch self {
        case let .reported(item, period): return "\(item)/\(period)"
        case let .market(field): return "\(field)/market"
        }
    }
}

/// A company's dashboard data, by currency, then by `Source.key`.
typealias CompanyData = [String: [String: [Point]]]

/// Everything the given lines need, every period and currency, in one request.
func fetchCompany(_ ticker: String, sources: [Source], periods: [String]) async throws -> CompanyData {
    var items = Set<String>(), fields = Set<String>()
    for source in sources {
        switch source {
        case let .reported(item, _): items.insert(item)
        case let .market(field): fields.insert(field)
        }
    }
    let series = try await API.current().dashboard(
        ticker: ticker, items: items.sorted(), periods: periods, market: fields.sorted())
    var data = CompanyData()
    for s in series {
        data[s.currency, default: [:]]["\(s.item)/\(s.period)"] = s.points
    }
    return data
}

enum APIError: Error {
    /// Cloudflare Access wants a sign-in: none yet, or it expired.
    case signIn
    /// The API refused the request or failed: its message.
    case server(String)
}

/// The equities API (lib's `equities/api`), at api.atec.pub behind
/// Cloudflare Access: everything the app reads. A person is let through with
/// their Access session (`cf-access-token`), the Mac and scripts with the
/// service token's headers.
struct API {
    let base: URL
    let headers: [String: String]

    /// One series of a company's dashboard, as the API returns it.
    struct DashboardSeries: Decodable {
        let item: String
        let period: String
        let currency: String
        let points: [Point]
    }

    /// From the settings (the Keychain, else the environment).
    static func current() -> API {
        let s = ServerSettings.load()
        var headers: [String: String] = [:]
        if let session = s.session, !session.isExpired {
            headers["cf-access-token"] = session.token
        } else if let token = s.serviceToken {
            headers["CF-Access-Client-Id"] = token.id
            headers["CF-Access-Client-Secret"] = token.secret
        }
        return API(base: s.serverURL, headers: headers)
    }

    func tickers() async throws -> [String] {
        try await get("tickers", [])
    }

    func dashboard(ticker: String, items: [String], periods: [String], market: [String]) async throws -> [DashboardSeries] {
        try await get("dashboard", [
            URLQueryItem(name: "ticker", value: ticker),
            URLQueryItem(name: "items", value: items.joined(separator: ",")),
            URLQueryItem(name: "periods", value: periods.joined(separator: ",")),
            URLQueryItem(name: "market", value: market.joined(separator: ",")),
        ])
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        let url = components.url!
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await API.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return try JSONDecoder().decode(T.self, from: data)
        // Access answers a request it won't let through with a redirect to
        // its login page (not followed: see NoRedirects); the API itself
        // with 401 or 403.
        case 300..<400, 401, 403:
            throw APIError.signIn
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.server(message ?? "\(url.host ?? "the server"): HTTP \(status)")
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    /// A redirect is Access sending us to its login page: stop there, so the
    /// app learns a sign-in is needed instead of getting the page's HTML.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// A message for an error.
func describe(_ error: Error) -> String {
    switch error {
    case APIError.signIn: return "Sign in to Cloudflare Access: Server settings, Sign in with email."
    case let APIError.server(message): return message
    default: return error.localizedDescription
    }
}
