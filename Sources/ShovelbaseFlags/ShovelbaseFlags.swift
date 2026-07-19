// ShovelbaseFlags — feature flags for shovelbase projects.
//
// Flags are managed on the portal's Analytics → Feature Flags page and read
// here from `<SHOVELBASE_URL>/flags/v1/flags`. The snapshot is cached for
// `cacheTtl` (default 60 s); lookups never throw — on network failure they
// serve the last snapshot, and before the first fetch they return your
// fallback value.
//
//     ShovelbaseFlags.configure(
//         url: "http://<host>/sb/<project-ref>",   // SHOVELBASE_URL
//         apiKey: "<anon key>"
//     )
//     if await ShovelbaseFlags.shared.isEnabled("new-checkout") { … }
//     let all = await ShovelbaseFlags.shared.getAll()   // ["new-checkout": true, …]
//     await ShovelbaseFlags.shared.refresh()            // bypass the cache
//     ShovelbaseFlags.shared.peek("new-checkout")       // sync, last-known value
import Foundation

public final class ShovelbaseFlags: @unchecked Sendable {

    public struct Options {
        /// How long a fetched snapshot is served before re-fetching. Default 60 s.
        public var cacheTtl: TimeInterval = 60

        public init() {}
    }

    public static let shared = ShovelbaseFlags()

    /// Call once, early (e.g. in `application(_:didFinishLaunching…)`).
    /// `url` is the project URL (`http://<host>/sb/<ref>`), `apiKey` the anon key.
    public static func configure(url: String, apiKey: String, options: Options = Options()) {
        shared.configure(url: url, apiKey: apiKey, options: options)
    }

    // MARK: - Internal state (all mutated under `lock`)

    private let lock = NSLock()
    private let session: URLSession
    private var endpoint: URL?
    private var apiKey = ""
    private var options = Options()
    private var snapshot: [String: Bool]?
    private var fetchedAt = Date.distantPast
    private var inflight: Task<Void, Never>?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    private func configure(url: String, apiKey: String, options: Options) {
        var base = url
        while base.hasSuffix("/") { base.removeLast() }
        lock.lock()
        self.endpoint = URL(string: "\(base)/flags/v1/flags")
        self.apiKey = apiKey
        self.options = options
        self.options.cacheTtl = max(options.cacheTtl, 1)
        lock.unlock()
    }

    // MARK: - Public API

    /// Whether a flag is on. Fetches (or re-fetches after the TTL) the snapshot
    /// first; `fallback` is returned when the flag doesn't exist or nothing has
    /// ever been fetched successfully.
    public func isEnabled(_ name: String, fallback: Bool = false) async -> Bool {
        await ensureFresh()
        return peek(name, fallback: fallback)
    }

    /// All flags as `[name: enabled]` (empty before the first successful fetch).
    public func getAll() async -> [String: Bool] {
        await ensureFresh()
        lock.lock()
        defer { lock.unlock() }
        return snapshot ?? [:]
    }

    /// Last-known value without a network round-trip — for render paths that
    /// can't await. Returns `fallback` until a fetch has completed.
    public func peek(_ name: String, fallback: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot?[name] ?? fallback
    }

    /// Re-fetches now regardless of the TTL; resolves to the fresh snapshot.
    @discardableResult
    public func refresh() async -> [String: Bool] {
        lock.lock()
        fetchedAt = Date.distantPast
        lock.unlock()
        return await getAll()
    }

    // MARK: - Fetching

    private func ensureFresh() async {
        let task: Task<Void, Never>
        lock.lock()
        if snapshot != nil, Date().timeIntervalSince(fetchedAt) < options.cacheTtl {
            lock.unlock()
            return
        }
        // One request at a time; concurrent lookups share it.
        if let existing = inflight {
            task = existing
        } else {
            task = Task { [weak self] in
                await self?.fetchSnapshot()
                guard let self else { return }
                self.lock.lock()
                self.inflight = nil
                self.lock.unlock()
            }
            inflight = task
        }
        lock.unlock()
        await task.value
    }

    private struct Payload: Decodable {
        let flags: [String: Bool]
    }

    private func fetchSnapshot() async {
        lock.lock()
        guard let endpoint else { // configure() not called
            lock.unlock()
            return
        }
        let key = apiKey
        lock.unlock()

        var request = URLRequest(url: endpoint)
        request.setValue(key, forHTTPHeaderField: "apikey")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return } // offline — keep serving the previous snapshot

        lock.lock()
        snapshot = payload.flags
        fetchedAt = Date()
        lock.unlock()
    }
}
