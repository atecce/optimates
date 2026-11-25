import SwiftProtobuf
import Foundation

/// A value at a date.
struct Point {
    let time: Date
    let value: Double
}

/// A named line on a chart.
struct Series: Identifiable {
    let name: String
    let points: [Point]
    var id: String { name }
}

/// What a chart line draws: the API's own terms (Generated/equities.pb.swift,
/// from lib's equities.proto), so the compiler checks every line against it.
enum Source: Hashable {
    /// A reported item for a period.
    case reported(Equities_V1_Item, Equities_V1_Period)
    /// A market series.
    case market(Equities_V1_MarketField)
}

/// A company's dashboard data, by currency, then by line.
typealias CompanyData = [String: [Source: [Point]]]

/// Everything the given lines need, each item in each of `periods`, every
/// currency, in one call.
/// The request for those lines: each item and field once, in the .proto's order.
func dashboardRequest(_ ticker: String, sources: [Source], periods: [Equities_V1_Period]) -> Equities_V1_DashboardRequest {
    var request = Equities_V1_DashboardRequest()
    request.ticker = ticker
    request.periods = periods
    var items = Set<Equities_V1_Item>(), fields = Set<Equities_V1_MarketField>()
    for source in sources {
        switch source {
        case let .reported(item, _): items.insert(item)
        case let .market(field): fields.insert(field)
        }
    }
    request.items = items.sorted { $0.rawValue < $1.rawValue }
    request.market = fields.sorted { $0.rawValue < $1.rawValue }
    return request
}

/// A dashboard reply as the charts read it: each series under its currency and
/// line, its days as dates.
func companyData(_ response: Equities_V1_DashboardResponse) -> CompanyData {
    var data = CompanyData()
    for series in response.series {
        let source: Source
        switch series.of {
        case let .reported(r)?: source = .reported(r.item, r.period)
        case let .market(f)?: source = .market(f)
        // A kind of series newer than this app: not drawn.
        case nil: continue
        }
        data[series.currency, default: [:]][source] = series.points.map {
            Point(time: Date(timeIntervalSince1970: TimeInterval($0.epochDay) * 86_400), value: $0.value)
        }
    }
    return data
}

enum APIError: Error {
    /// Cloudflare Access wants a sign-in: none yet, or it expired.
    case signIn
    /// The API refused the call or failed: its message.
    case server(String)
}

/// A call of the .proto's `Equities` service: its path, and the message
/// types it takes and returns, so a call can't send or expect the wrong one.
/// One per rpc; the messages themselves are generated (proto.sh).
struct Method<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message> {
    let path: String

    static var tickers: Method<Equities_V1_TickersRequest, Equities_V1_TickersResponse> {
        .init(path: "equities.v1.Equities/Tickers")
    }
    static var dashboard: Method<Equities_V1_DashboardRequest, Equities_V1_DashboardResponse> {
        .init(path: "equities.v1.Equities/Dashboard")
    }
    static var holdings: Method<Equities_V1_HoldingsRequest, Equities_V1_HoldingsResponse> {
        .init(path: "equities.v1.Equities/Holdings")
    }
    static var macro: Method<Equities_V1_MacroRequest, Equities_V1_MacroResponse> {
        .init(path: "equities.v1.Equities/Macro")
    }
}

/// The equities API (lib's `equities/api`), at api.atec.pub behind
/// Cloudflare Access. A person is let through with their Access session
/// (`cf-access-token`), the Mac and scripts with the service token's headers.
///
/// Calls are the Connect protocol's unary calls (connectrpc.com/docs/protocol):
/// the request message POSTed as protobuf to `/<package>.<Service>/<Method>`,
/// the reply the response message, or a status with `{"code", "message"}`.
struct API {
    let base: URL
    let headers: [String: String]

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

    func call<Input, Output>(_ method: Method<Input, Output>, _ input: Input) async throws -> Output {
        try Output(serializedBytes: try await raw(method.path, try input.serializedData()))
    }

    /// A call as bytes: the request message in, the reply message out. What
    /// `call` does once typed; on its own, it replays a kept request (pinned
    /// replies, refreshed at launch) without knowing its messages' types.
    func raw(_ path: String, _ body: Data) async throws -> Data {
        // No credentials: Access would only send us to its login page.
        guard !headers.isEmpty else { throw APIError.signIn }
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("30000", forHTTPHeaderField: "Connect-Timeout-Ms")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body

        // In a task of its own: SwiftUI cancels a view's task when it thinks
        // the view went away (on iPhone, while opening a company), and
        // URLSession would drop the call half done. Finished, its result goes
        // to whoever still waits.
        let sent = request
        let (data, response) = try await Task { try await API.session.data(for: sent) }.value
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 200, http?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/proto") == true {
            return data
        }
        // A redirect is Access sending us to its login page (not followed:
        // see NoRedirects): the session is gone or no longer accepted.
        if (300..<400).contains(status) { throw APIError.signIn }
        let error = try? JSONDecoder().decode(ConnectError.self, from: data)
        switch error?.code {
        case "unauthenticated", "permission_denied": throw APIError.signIn
        case _ where status == 401 || status == 403: throw APIError.signIn
        default: throw APIError.server(error?.message ?? "\(base.host ?? "the server"): HTTP \(status)")
        }
    }

    /// A Connect error's body.
    private struct ConnectError: Decodable {
        let code: String
        let message: String?
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// A line's value at `date`: its last point on or before it, as a dashboard
/// reads a quarter's figure until the next. nil before its first point, and
/// over a year after its last (a delisting, a change of currency).
extension Series {
    func value(at date: Date) -> Double? {
        guard let p = points.last(where: { $0.time <= date }),
              date.timeIntervalSince(p.time) < 400 * 86_400 else { return nil }
        return p.value
    }
}

/// Whether `error` is only a cancellation: nothing to show.
func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

/// A message for an error.
func describe(_ error: Error) -> String {
    switch error {
    case APIError.signIn: return "Sign in to Cloudflare Access: Server settings, Sign in with email."
    case let APIError.server(message): return message
    default: return error.localizedDescription
    }
}
