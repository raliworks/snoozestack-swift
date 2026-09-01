// SnoozestackSignals — Mixpanel-style event tracking for snoozestack projects.
//
// Events are queued (and persisted to disk, so they survive app kills),
// batched, and POSTed to `<SNOOZESTACK_URL>/signals/v1/events`, where the
// portal charts them on the Signals page.
//
//     SnoozestackSignals.configure(
//         url: "http://<host>/sb/<project-ref>",   // SNOOZESTACK_URL
//         apiKey: "<anon key>"
//     )
//     SnoozestackSignals.shared.identify(user.id)
//     SnoozestackSignals.shared.track("signup", properties: ["plan": "pro"])
//
// `SnoozestackAnalytics` remains as a deprecated alias (see the bottom of this
// file, and the SnoozestackAnalytics compat target).
//
// Tracking never throws and never blocks the caller; all work happens on a
// private serial queue. Failed batches are retried on the next flush.
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

public final class SnoozestackSignals {

    public struct Options {
        /// How often the queue is flushed to the server. Default 10 s.
        public var flushInterval: TimeInterval = 10
        /// Queue length that triggers an immediate flush. Default 20, max 100.
        public var batchSize: Int = 20
        /// Oldest events drop first past this size. Default 1000.
        public var maxQueueSize: Int = 1000

        public init() {}
    }

    public static let shared = SnoozestackSignals()

    /// Call once, early (e.g. in `application(_:didFinishLaunching…)`).
    /// `url` is the project URL (`http://<host>/sb/<ref>`), `apiKey` the anon key.
    public static func configure(url: String, apiKey: String, options: Options = Options()) {
        shared.configure(url: url, apiKey: apiKey, options: options)
    }

    // MARK: - Internal state (all mutated on `queue`)

    private let queue = DispatchQueue(label: "com.snoozestack.signals")
    private let session: URLSession
    private var endpoint: URL?
    private var apiKey = ""
    private var options = Options()
    private var events: [[String: Any]] = []
    private var distinctId = ""
    private var isFlushing = false
    private var timer: DispatchSourceTimer?

    private static let distinctIdKey = "snoozestack_distinct_id"
    private static let maxBatch = 100 // server-side cap per request

    // Reserved events that assert identity rather than record activity. The
    // server folds them into its identity graph and leaves them out of charts.
    private static let identifyEvent = "$identify"
    private static let aliasEvent = "$alias"
    private static let resetEvent = "$reset"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    private func configure(url: String, apiKey: String, options: Options) {
        queue.async {
            var base = url
            while base.hasSuffix("/") { base.removeLast() }
            self.endpoint = URL(string: "\(base)/signals/v1/events")
            self.apiKey = apiKey
            self.options = options
            self.options.batchSize = min(max(options.batchSize, 1), Self.maxBatch)
            self.distinctId = Self.loadOrCreateDistinctId()
            self.events = Self.loadPersistedQueue()
            self.startTimer()
        }
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.flush() }
        #endif
    }

    // MARK: - Public API

    /// Ties subsequent events to your user id (e.g. the auth user id).
    ///
    /// The anonymous id in use until now is sent along so the server can merge
    /// the two — activity from before sign-up and the account it became stay
    /// one person in every chart and funnel. Safe to call on every launch;
    /// re-identifying the same id is a no-op.
    public func identify(_ id: String) {
        guard !id.isEmpty else { return }
        let ts = Self.isoFormatter.string(from: Date())
        queue.async {
            let previous = self.distinctId
            guard previous != id else { return }
            self.distinctId = id
            UserDefaults.standard.set(id, forKey: Self.distinctIdKey)
            self.trackLocked("event", Self.identifyEvent, ts: ts, properties: ["$anon_id": previous])
        }
    }

    /// Asserts that another id is the same person as the current one, for
    /// links `identify` doesn't cover. Merging two ids that each already name
    /// an account is refused.
    public func alias(_ otherId: String) {
        guard !otherId.isEmpty else { return }
        let ts = Self.isoFormatter.string(from: Date())
        queue.async {
            guard otherId != self.distinctId else { return }
            self.trackLocked("event", Self.aliasEvent, ts: ts, properties: ["$anon_id": otherId])
        }
    }

    /// Reverts to a fresh anonymous id (call on sign-out). Sends immediately so
    /// the next person on a shared device starts clean rather than inheriting
    /// the identity of whoever just signed out.
    public func reset() {
        let ts = Self.isoFormatter.string(from: Date())
        queue.async {
            UserDefaults.standard.removeObject(forKey: Self.distinctIdKey)
            self.distinctId = Self.loadOrCreateDistinctId()
            self.trackLocked("event", Self.resetEvent, ts: ts, properties: [:])
            self.flushLocked()
        }
    }

    /// Queues an event. Fire-and-forget: returns immediately, never throws.
    /// Property values must be JSON-encodable (String/number/Bool/array/dict);
    /// anything else is stored via `String(describing:)`.
    public func track(_ name: String, properties: [String: Any] = [:]) {
        enqueue("event", name, properties: properties)
    }

    /// Queues a log signal — not attributed to a user (no distinct_id).
    /// Reserved `properties` keys: `level`, `source`. Fire-and-forget: never
    /// throws.
    public func log(_ message: String, properties: [String: Any] = [:]) {
        enqueue("log", message, properties: properties)
    }

    /// Queues a metric signal — not attributed to a user (no distinct_id).
    /// `value` is required; reserved `properties` key: `unit`.
    /// Fire-and-forget: never throws.
    public func metric(_ name: String, value: Double, properties: [String: Any] = [:]) {
        guard value.isFinite else { return }
        var props = properties
        props["value"] = value
        enqueue("metric", name, properties: props)
    }

    /// Queues a trace signal — not attributed to a user (no distinct_id).
    /// Reserved `properties` keys: `span_id`, `parent_span_id`,
    /// `duration_ms`. Fire-and-forget: never throws.
    public func trace(_ name: String, properties: [String: Any] = [:]) {
        enqueue("trace", name, properties: properties)
    }

    /// Queues an audit signal — not attributed to a user via distinct_id; put
    /// the actor in `properties["actor"]` instead. `action` is conventionally
    /// a dotted key, e.g. `"billing.plan.changed"`. Fire-and-forget: never
    /// throws.
    public func audit(_ action: String, properties: [String: Any] = [:]) {
        enqueue("audit", action, properties: properties)
    }

    /// Queues one signal of any type. Trims and drops on an empty name, same
    /// as the original `track`.
    private func enqueue(_ type: String, _ name: String, properties: [String: Any]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ts = Self.isoFormatter.string(from: Date())
        queue.async { self.trackLocked(type, trimmed, ts: ts, properties: properties) }
    }

    /// Queues one signal. Must already be running on `queue`. Identity
    /// stitching (distinct_id) is only ever attached to type "event" — the
    /// portal's ingest route scopes it the same way, so this just keeps the
    /// wire payload matching what it stores.
    private func trackLocked(_ type: String, _ name: String, ts: String, properties: [String: Any]) {
        guard endpoint != nil else { return } // configure() not called
        var props = Self.defaultProperties
        for (key, value) in properties { props[key] = Self.jsonSafe(value) }
        var signal: [String: Any] = [
            "type": type,
            "name": name,
            "ts": ts,
            "insert_id": UUID().uuidString.lowercased(),
            "props": props,
        ]
        if type == "event" { signal["distinct_id"] = distinctId }
        events.append(signal)
        if events.count > options.maxQueueSize {
            events.removeFirst(events.count - options.maxQueueSize)
        }
        persistQueue()
        if events.count >= options.batchSize { flushLocked() }
    }

    /// Sends everything queued now (also called automatically on a timer,
    /// when the batch size is reached, and when the app is backgrounded).
    public func flush() {
        queue.async { self.flushLocked() }
    }

    // MARK: - Flushing (on `queue`)

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + options.flushInterval, repeating: options.flushInterval)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        timer = t
    }

    private func flushLocked() {
        guard let endpoint, !isFlushing, !events.isEmpty else { return }
        isFlushing = true

        #if canImport(UIKit) && !os(watchOS)
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        let finishBackgroundTask = {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        #else
        let finishBackgroundTask = {}
        #endif

        let batch = Array(events.prefix(Self.maxBatch))
        guard JSONSerialization.isValidJSONObject(["events": batch]),
              let body = try? JSONSerialization.data(withJSONObject: ["events": batch])
        else {
            // Should be unreachable (props are sanitized on track) — drop the
            // batch rather than wedge the queue forever.
            events.removeFirst(batch.count)
            persistQueue()
            isFlushing = false
            finishBackgroundTask()
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")

        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { finishBackgroundTask(); return }
            self.queue.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Success — or a 4xx the server will never accept: drop the
                // batch. Network errors / 5xx / 429 keep it for the next tick.
                let drop = error == nil && status > 0 && status < 500 && status != 429
                if drop {
                    self.events.removeFirst(min(batch.count, self.events.count))
                    self.persistQueue()
                }
                self.isFlushing = false
                if drop && status < 300 && !self.events.isEmpty { self.flushLocked() }
                finishBackgroundTask()
            }
        }.resume()
    }

    // MARK: - Persistence

    private static var queueFileURL: URL? {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let folder = dir.appendingPathComponent("snoozestack", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Filename unchanged across the Analytics → Signals rename so events
        // already queued by an older build survive the upgrade.
        return folder.appendingPathComponent("analytics-queue.json")
    }

    private func persistQueue() {
        guard let url = Self.queueFileURL,
              JSONSerialization.isValidJSONObject(events),
              let data = try? JSONSerialization.data(withJSONObject: events)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadPersistedQueue() -> [[String: Any]] {
        guard let url = queueFileURL,
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return parsed
    }

    private static func loadOrCreateDistinctId() -> String {
        if let id = UserDefaults.standard.string(forKey: distinctIdKey), !id.isEmpty {
            return id
        }
        let id = "$anon-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(id, forKey: distinctIdKey)
        return id
    }

    // MARK: - Event helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static var defaultProperties: [String: Any] {
        var props: [String: Any] = ["$sdk": "snoozestack-swift"]
        #if os(iOS)
        props["$os"] = "iOS"
        #elseif os(macOS)
        props["$os"] = "macOS"
        #elseif os(tvOS)
        props["$os"] = "tvOS"
        #elseif os(watchOS)
        props["$os"] = "watchOS"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        props["$os_version"] = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            props["$app_version"] = version
        }
        return props
    }

    // Coerces a property value to something JSONSerialization accepts.
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let v as String: return v
        case let v as Bool: return v
        case let v as Int: return v
        case let v as Double: return v.isFinite ? v : String(describing: v)
        case let v as Float: return v.isFinite ? Double(v) : String(describing: v)
        case let v as NSNumber: return v
        case is NSNull: return NSNull()
        case let v as Date: return isoFormatter.string(from: v)
        case let v as URL: return v.absoluteString
        case let v as [Any]: return v.map { jsonSafe($0) }
        case let v as [String: Any]: return v.mapValues { jsonSafe($0) }
        default: return String(describing: value)
        }
    }
}

/// Renamed to ``SnoozestackSignals``; kept as an alias so existing call sites
/// (`SnoozestackAnalytics.configure`, `SnoozestackAnalytics.shared`) keep working.
@available(*, deprecated, renamed: "SnoozestackSignals")
public typealias SnoozestackAnalytics = SnoozestackSignals
