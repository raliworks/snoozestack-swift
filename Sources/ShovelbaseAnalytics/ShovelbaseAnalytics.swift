// ShovelbaseAnalytics — Mixpanel-style event tracking for shovelbase projects.
//
// Events are queued (and persisted to disk, so they survive app kills),
// batched, and POSTed to `<SHOVELBASE_URL>/analytics/v1/events`, where the
// portal charts them on Observability → Analytics.
//
//     ShovelbaseAnalytics.configure(
//         url: "http://<host>/sb/<project-ref>",   // SHOVELBASE_URL
//         apiKey: "<anon key>"
//     )
//     ShovelbaseAnalytics.shared.identify(user.id)
//     ShovelbaseAnalytics.shared.track("signup", properties: ["plan": "pro"])
//
// Tracking never throws and never blocks the caller; all work happens on a
// private serial queue. Failed batches are retried on the next flush.
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

public final class ShovelbaseAnalytics {

    public struct Options {
        /// How often the queue is flushed to the server. Default 10 s.
        public var flushInterval: TimeInterval = 10
        /// Queue length that triggers an immediate flush. Default 20, max 100.
        public var batchSize: Int = 20
        /// Oldest events drop first past this size. Default 1000.
        public var maxQueueSize: Int = 1000

        public init() {}
    }

    public static let shared = ShovelbaseAnalytics()

    /// Call once, early (e.g. in `application(_:didFinishLaunching…)`).
    /// `url` is the project URL (`http://<host>/sb/<ref>`), `apiKey` the anon key.
    public static func configure(url: String, apiKey: String, options: Options = Options()) {
        shared.configure(url: url, apiKey: apiKey, options: options)
    }

    // MARK: - Internal state (all mutated on `queue`)

    private let queue = DispatchQueue(label: "com.shovelbase.analytics")
    private let session: URLSession
    private var endpoint: URL?
    private var apiKey = ""
    private var options = Options()
    private var events: [[String: Any]] = []
    private var distinctId = ""
    private var isFlushing = false
    private var timer: DispatchSourceTimer?

    private static let distinctIdKey = "shovelbase_distinct_id"
    private static let maxBatch = 100 // server-side cap per request

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    private func configure(url: String, apiKey: String, options: Options) {
        queue.async {
            var base = url
            while base.hasSuffix("/") { base.removeLast() }
            self.endpoint = URL(string: "\(base)/analytics/v1/events")
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
    public func identify(_ id: String) {
        guard !id.isEmpty else { return }
        queue.async {
            self.distinctId = id
            UserDefaults.standard.set(id, forKey: Self.distinctIdKey)
        }
    }

    /// Reverts to a fresh anonymous id (call on sign-out).
    public func reset() {
        queue.async {
            UserDefaults.standard.removeObject(forKey: Self.distinctIdKey)
            self.distinctId = Self.loadOrCreateDistinctId()
        }
    }

    /// Queues an event. Fire-and-forget: returns immediately, never throws.
    /// Property values must be JSON-encodable (String/number/Bool/array/dict);
    /// anything else is stored via `String(describing:)`.
    public func track(_ name: String, properties: [String: Any] = [:]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ts = Self.isoFormatter.string(from: Date())
        queue.async {
            guard self.endpoint != nil else { return } // configure() not called
            var props = Self.defaultProperties
            for (key, value) in properties { props[key] = Self.jsonSafe(value) }
            self.events.append([
                "name": trimmed,
                "distinct_id": self.distinctId,
                "ts": ts,
                "insert_id": UUID().uuidString.lowercased(),
                "props": props,
            ])
            if self.events.count > self.options.maxQueueSize {
                self.events.removeFirst(self.events.count - self.options.maxQueueSize)
            }
            self.persistQueue()
            if self.events.count >= self.options.batchSize { self.flushLocked() }
        }
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
        let folder = dir.appendingPathComponent("shovelbase", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
        var props: [String: Any] = ["$sdk": "shovelbase-swift"]
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
