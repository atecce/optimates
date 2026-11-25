import Foundation
import SwiftData
import SwiftProtobuf

/// A reply from the API as it came: its protobuf bytes, under a key
/// ("tickers", "dashboard/AAPL"). The .proto stays the only schema: nothing
/// here needs changing when it does, and a reply the app can no longer read
/// is simply fetched again.
@Model
final class CachedReply {
    @Attribute(.unique) var key: String
    @Attribute(.externalStorage) var bytes: Data
    /// When the API sent it.
    var fetched: Date
    /// When it was last read: the least recently used go first.
    var used: Date

    init(key: String, bytes: Data, fetched: Date) {
        self.key = key
        self.bytes = bytes
        self.fetched = fetched
        used = fetched
    }
}

/// The most recently used replies, on the device (SwiftData, in Caches: the
/// system may clear it, and everything in it can be fetched again). A screen
/// shows what's here at once, then what the API says.
@MainActor
final class ReplyCache {
    /// How many replies are kept: the company list and about this many
    /// companies, a few MB.
    let limit: Int
    private let context: ModelContext?

    static let shared = ReplyCache(container: try? ModelContainer(
        for: CachedReply.self,
        configurations: ModelConfiguration(url: URL.cachesDirectory.appending(path: "replies.store"))))

    /// No container (the store couldn't open): nothing is cached.
    init(container: ModelContainer?, limit: Int = 40) {
        context = container.map { ModelContext($0) }
        self.limit = limit
    }

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

    func put<M: SwiftProtobuf.Message>(_ key: String, _ message: M, fetched: Date = Date()) {
        guard let context, let bytes = try? message.serializedData() else { return }
        if let reply = find(key) {
            reply.bytes = bytes
            reply.fetched = fetched
            reply.used = fetched
        } else {
            context.insert(CachedReply(key: key, bytes: bytes, fetched: fetched))
        }
        try? context.save()
        evict()
        try? context.save()
    }

    /// Everything, as when signing out.
    func clear() {
        try? context?.delete(model: CachedReply.self)
        try? context?.save()
    }

    var count: Int { (try? context?.fetchCount(FetchDescriptor<CachedReply>())) ?? 0 }

    /// Keep the `limit` most recently used.
    private func evict() {
        var descriptor = FetchDescriptor<CachedReply>(sortBy: [SortDescriptor(\.used, order: .reverse)])
        descriptor.fetchOffset = limit
        for old in (try? context?.fetch(descriptor)) ?? [] {
            context?.delete(old)
        }
    }
}
