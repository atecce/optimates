import Connect
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
func fetchCompany(_ ticker: String, sources: [Source], periods: [Equities_V1_Period]) async throws -> CompanyData {
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

    let response = try await API.current().call { await $0.dashboard(request: request, headers: $1) }
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

/// The equities API (lib's `equities/api`), at api.atec.pub behind
/// Cloudflare Access, over Connect. A person is let through with their
/// Access session (`cf-access-token`), the Mac and scripts with the service
/// token's headers.
struct API {
    let client: Equities_V1_EquitiesClient
    let headers: Headers
    let signedIn: Bool

    /// From the settings (the Keychain, else the environment).
    static func current() -> API {
        let s = ServerSettings.load()
        var headers: Headers = [:]
        if let session = s.session, !session.isExpired {
            headers["cf-access-token"] = [session.token]
        } else if let token = s.serviceToken {
            headers["CF-Access-Client-Id"] = [token.id]
            headers["CF-Access-Client-Secret"] = [token.secret]
        }
        let config = ProtocolClientConfig(host: s.serverURL.absoluteString, networkProtocol: .connect,
                                          codec: ProtoCodec(), timeout: 30)
        return API(client: Equities_V1_EquitiesClient(client: ProtocolClient(config: config)),
                   headers: headers, signedIn: !headers.isEmpty)
    }

    func tickers() async throws -> [String] {
        try await call { await $0.tickers(request: Equities_V1_TickersRequest(), headers: $1) }.tickers
    }

    /// Make a call, its failure an APIError.
    func call<Output>(_ rpc: (Equities_V1_EquitiesClient, Headers) async -> ResponseMessage<Output>) async throws -> Output {
        // No credentials: Access would only send us to its login page.
        guard signedIn else { throw APIError.signIn }
        let response = await rpc(client, headers)
        switch response.result {
        case let .success(output):
            return output
        case let .failure(error):
            switch error.code {
            // The API refusing Access's assertion, or Access's login page
            // (a session it no longer accepts, followed to its HTML).
            case .unauthenticated, .permissionDenied:
                throw APIError.signIn
            case .unknown where (error.message ?? "").contains("text/html"):
                throw APIError.signIn
            default:
                throw APIError.server(error.message ?? "\(error.code)")
            }
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
