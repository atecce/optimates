import Foundation
import SwiftData
import SwiftProtobuf
import SwiftUI

/// A reply from the API as it came: its protobuf bytes, under a key
/// ("tickers", "dashboard/AAPL", "macro"), and the call that brought it (its
/// path and request bytes), so it can be asked again without knowing its
/// types. The .proto stays the only schema: nothing here needs changing when
/// it does, and a reply the app can no longer read is simply fetched again.
@Model
final class CachedReply {
    @Attribute(.unique) var key: String
    @Attribute(.externalStorage) var bytes: Data
    /// When the API sent it.
    var fetched: Date
    /// When it was last read: the least recently used go first.
    var used: Date
    /// The call: "equities.v1.Equities/Dashboard", and its request message.
    var path: String?
    var request: Data?

    init(key: String, bytes: Data, fetched: Date) {
        self.key = key
        self.bytes = bytes
        self.fetched = fetched
        used = fetched
    }
}

/// Which replies are pinned: kept however long they go unread, and
/// refreshed whenever the app opens. In UserDefaults (comma-separated keys),
/// where the screens' star buttons read and write them too.
enum Pins {
    static let defaultsKey = "pinnedReplies"
    /// Pinned from the start: the economic screens, and Apple, Nvidia and
    /// Tesla (a company is kept from the first time it's opened).
    static let initial = "dashboard/AAPL,dashboard/NVDA,dashboard/TSLA,macro,realestate,yieldcurve"

    static func parse(_ s: String) -> Set<String> {
        Set(s.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    static func format(_ keys: Set<String>) -> String { keys.sorted().joined(separator: ",") }

    /// `key` pinned or not, in the comma-separated list `s`.
    static func toggled(_ key: String, in s: String) -> String {
        var keys = parse(s)
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        return format(keys)
    }
}

/// The API's replies, on the device (SwiftData, in Application Support, out
/// of backups: everything in it can be fetched again, but the system won't
/// clear it to make room). A screen shows what's here at once, then what the
/// API says. Pinned replies stay; of the rest, the most recently used.
@MainActor
final class ReplyCache {
    /// How many unpinned replies are kept: about this many companies, a few
    /// MB.
    let limit: Int
    private let context: ModelContext?
    private let defaults: UserDefaults

    static let shared = ReplyCache(container: openStore(), defaults: .standard)

    /// Application Support/replies/replies.store; the folder excluded from
    /// backup. (The cache was in Caches before, where iOS may empty it.)
    private static func openStore() -> ModelContainer? {
        var dir = URL.applicationSupportDirectory.appending(path: "replies", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "replies.store"))
        return try? ModelContainer(for: CachedReply.self,
                                   configurations: ModelConfiguration(url: dir.appending(path: "replies.store")))
    }

    /// No container (the store couldn't open): nothing is cached.
    init(container: ModelContainer?, limit: Int = 40, defaults: UserDefaults = .standard) {
        context = container.map { ModelContext($0) }
        self.limit = limit
        self.defaults = defaults
    }

    var pinned: Set<String> { Pins.parse(defaults.string(forKey: Pins.defaultsKey) ?? Pins.initial) }

    private func find(_ key: String) -> CachedReply? {
        var descriptor = FetchDescriptor<CachedReply>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context?.fetch(descriptor).first
    }

    /// The reply kept for `key`, and when it was fetched.
    func get<M: SwiftProtobuf.Message>(_ type: M.Type, _ key: String) -> (M, Date)? {
        guard let reply = find(key), let message = try? M(serializedBytes: reply.bytes) else { return nil }
        reply.used = Date()
        try? context?.save()
        return (message, reply.fetched)
    }

    /// Ask the API, and keep the reply with its call.
    func fetch<Input, Output>(_ key: String, _ method: Method<Input, Output>, _ input: Input) async throws -> Output {
        let body = try input.serializedData()
        let data = try await API.current().raw(method.path, body)
        let output = try Output(serializedBytes: data)
        store(key, data, path: method.path, request: body)
        return output
    }

    func put<M: SwiftProtobuf.Message>(_ key: String, _ message: M, fetched: Date = Date()) {
        guard let bytes = try? message.serializedData() else { return }
        store(key, bytes, fetched: fetched)
    }

    private func store(_ key: String, _ bytes: Data, path: String? = nil, request: Data? = nil, fetched: Date = Date()) {
        guard let context else { return }
        let reply = find(key) ?? {
            let r = CachedReply(key: key, bytes: bytes, fetched: fetched)
            context.insert(r)
            return r
        }()
        reply.bytes = bytes
        reply.fetched = fetched
        reply.used = fetched
        if let path, let request { (reply.path, reply.request) = (path, request) }
        try? context.save()
        evict()
        try? context.save()
    }

    /// Ask the API again for every pinned reply it has the call for: at
    /// launch, so they're fresh before they're opened. Failures leave the
    /// kept reply as it was.
    func refreshPinned() async {
        let api = API.current()
        for key in pinned.sorted() {
            guard let reply = find(key), let path = reply.path, let request = reply.request else { continue }
            if let data = try? await api.raw(path, request) {
                store(key, data, path: path, request: request)
            }
        }
    }

    /// Everything, as when signing out.
    func clear() {
        try? context?.delete(model: CachedReply.self)
        try? context?.save()
    }

    var count: Int { (try? context?.fetchCount(FetchDescriptor<CachedReply>())) ?? 0 }

    /// Keep the pinned, and the `limit` most recently used of the rest.
    private func evict() {
        let pins = pinned
        let descriptor = FetchDescriptor<CachedReply>(sortBy: [SortDescriptor(\.used, order: .reverse)])
        let unpinned = ((try? context?.fetch(descriptor)) ?? []).filter { !pins.contains($0.key) }
        for old in unpinned.dropFirst(limit) {
            context?.delete(old)
        }
    }
}

/// A star in a screen's toolbar: pin its reply (kept on the device however
/// long it goes unread, refreshed when the app opens), or unpin it.
struct PinButton: View {
    let key: String
    @Binding var pins: String

    private var isPinned: Bool { Pins.parse(pins).contains(key) }

    var body: some View {
        Button {
            pins = Pins.toggled(key, in: pins)
        } label: {
            Label(isPinned ? "Unpin: no longer kept offline" : "Pin: keep offline",
                  systemImage: isPinned ? "star.fill" : "star")
        }
    }
}
