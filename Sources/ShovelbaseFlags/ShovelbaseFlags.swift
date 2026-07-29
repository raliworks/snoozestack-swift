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
    private var rules: [String: Rule]?
    private var fetchedAt = Date.distantPast
    private var inflight: Task<Void, Never>?

    /// Shared with `ShovelbaseSignals` — the same key, on purpose.
    static let distinctIdKey = "shovelbase_distinct_id"

    /// One flag's rule as the server sends it. Rules ship rather than a
    /// pre-computed answer so a single cached snapshot serves every user.
    struct Rule: Decodable {
        let enabled: Bool
        let rollout: Int
    }

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

    // MARK: - Bucketing

    /// Which of 100 buckets a user falls into for a given flag.
    ///
    /// FNV-1a over the UTF-8 bytes of `"<flag>:<id>"`, finished with
    /// MurmurHash3's avalanche step. Plain arithmetic with no crypto
    /// dependency, so `peek` stays synchronous, and byte-for-byte identical to
    /// the JavaScript SDK — the same user must land in the same bucket on
    /// every platform, and must keep doing so across SDK upgrades.
    ///
    /// The flag name is hashed in so someone in the first 10% of one flag
    /// isn't thereby in the first 10% of every other one.
    public static func bucket(_ flagName: String, _ distinctId: String) -> Int {
        var h: UInt32 = 0x811c_9dc5
        for byte in "\(flagName):\(distinctId)".utf8 {
            h ^= UInt32(byte)
            h = h &* 0x0100_0193
        }
        h ^= h >> 16
        h = h &* 0x85eb_ca6b
        h ^= h >> 13
        h = h &* 0xc2b2_ae35
        h ^= h >> 16
        return Int(h % 100)
    }

    /// `enabled` is the master switch — off means off for everyone whatever
    /// the rollout says, so a ramp can be killed without losing the percentage
    /// it reached. 0 and 100 short-circuit so they never depend on the hash.
    private static func evaluate(_ rule: Rule, _ flagName: String, _ distinctId: String) -> Bool {
        guard rule.enabled else { return false }
        if rule.rollout >= 100 { return true }
        if rule.rollout <= 0 { return false }
        return bucket(flagName, distinctId) < rule.rollout
    }

    // MARK: - Public API

    /// Names the user rollouts bucket on. Shares storage with
    /// `ShovelbaseSignals.identify`, so calling either is enough.
    public func identify(_ id: String) {
        guard !id.isEmpty else { return }
        UserDefaults.standard.set(id, forKey: Self.distinctIdKey)
    }

    /// Whether a flag is on for the current user. Fetches (or re-fetches after
    /// the TTL) the snapshot first; `fallback` is returned when the flag
    /// doesn't exist or nothing has ever been fetched successfully.
    public func isEnabled(_ name: String, fallback: Bool = false) async -> Bool {
        await ensureFresh()
        return peek(name, fallback: fallback)
    }

    /// Whether a flag is on for a specific user, ignoring the stored identity —
    /// for server-side or multi-user callers. Uses the same cached snapshot,
    /// so it costs no extra requests.
    public func isEnabled(_ name: String, for distinctId: String, fallback: Bool = false) async -> Bool {
        await ensureFresh()
        lock.lock()
        defer { lock.unlock() }
        guard let rule = rules?[name] else { return fallback }
        return Self.evaluate(rule, name, distinctId)
    }

    /// All flags as `[name: enabled]` for the current user (empty before the
    /// first successful fetch).
    public func getAll() async -> [String: Bool] {
        await getAll(for: Self.currentDistinctId())
    }

    /// All flags as `[name: enabled]` for a specific user.
    public func getAll(for distinctId: String) async -> [String: Bool] {
        await ensureFresh()
        lock.lock()
        defer { lock.unlock() }
        var out: [String: Bool] = [:]
        for (name, rule) in rules ?? [:] {
            out[name] = Self.evaluate(rule, name, distinctId)
        }
        return out
    }

    /// Last-known value without a network round-trip — for render paths that
    /// can't await. Returns `fallback` until a fetch has completed.
    public func peek(_ name: String, fallback: Bool = false) -> Bool {
        let id = Self.currentDistinctId()
        lock.lock()
        defer { lock.unlock() }
        guard let rule = rules?[name] else { return fallback }
        return Self.evaluate(rule, name, id)
    }

    /// Re-fetches now regardless of the TTL; resolves to the current values.
    @discardableResult
    public func refresh() async -> [String: Bool] {
        lock.lock()
        fetchedAt = Date.distantPast
        lock.unlock()
        return await getAll()
    }

    // MARK: - Identity

    /// The id rollouts bucket on, shared with `ShovelbaseSignals` through the
    /// same `UserDefaults` key so events and experiments describe one person.
    /// Mints and stores an anonymous id when signals hasn't set one.
    static func currentDistinctId() -> String {
        if let id = UserDefaults.standard.string(forKey: distinctIdKey), !id.isEmpty {
            return id
        }
        let id = "$anon-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(id, forKey: distinctIdKey)
        return id
    }

    // MARK: - Fetching

    private func ensureFresh() async {
        let task: Task<Void, Never>
        lock.lock()
        if rules != nil, Date().timeIntervalSince(fetchedAt) < options.cacheTtl {
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
        let rules: [String: Rule]?
        /// The pre-rollout response shape, still sent for older SDKs.
        let flags: [String: Bool]?
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

        // A server from before percentage rollouts sends booleans only.
        let parsed: [String: Rule]
        if let rules = payload.rules {
            parsed = rules
        } else if let flags = payload.flags {
            parsed = flags.mapValues { Rule(enabled: $0, rollout: 100) }
        } else {
            return
        }

        lock.lock()
        rules = parsed
        fetchedAt = Date()
        lock.unlock()
    }
}
