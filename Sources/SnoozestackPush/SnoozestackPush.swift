// SnoozestackPush — registers a device for push notifications with a snoozestack
// project.
//
//     func application(_ app: UIApplication,
//                      didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
//         Task { try? await snoozestack.push.register(deviceToken: token) }
//     }
//
//     // on sign-out:
//     try await snoozestack.push.unregister()
//
// The token is POSTed to `<SNOOZESTACK_URL>/push/v1/devices`, where the project
// records it against the signed-in user. Sending is server-side: a queue
// trigger names a user and the server fans out to that user's devices. There is
// deliberately no send method here — a client that could enqueue a push could
// notify anybody.
//
// This does NOT ask for permission: `requestAuthorization` decides when the
// system prompt appears, and that is the app's call, not the SDK's.
import Foundation

public final class SnoozestackPush {

    /// Which APNs world a build belongs to. Decided when the app is *built*,
    /// not at send time — a token from an Xcode build is only valid against
    /// sandbox, a TestFlight/App Store token only against production, and the
    /// two look identical.
    public enum Environment: String, Sendable {
        case sandbox
        case production
    }

    public enum PushError: Error, LocalizedError {
        case notConfigured
        case simulatorUnsupported
        case server(status: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "SnoozestackPush.configure(url:apiKey:) has not been called"
            case .simulatorUnsupported:
                return "The simulator cannot receive APNs pushes (use `xcrun simctl push` instead)"
            case let .server(status, message):
                return "snoozestack push registration failed (\(status)): \(message)"
            }
        }
    }

    public static let shared = SnoozestackPush()

    /// Call once, early — `Snoozestack.createClient` does it for you.
    public static func configure(url: String, apiKey: String) {
        shared.configure(url: url, apiKey: apiKey)
    }

    /// Supplies the signed-in user's access token, so the server can bind the
    /// device to `auth.users.id`. `Snoozestack.createClient` wires this to the
    /// auth client; standalone users may set it themselves. Returning nil
    /// registers the device unattached, and the next launch binds it.
    public var accessTokenProvider: (@Sendable () async -> String?)?

    private let lock = NSLock()
    private let session: URLSession
    private var endpoint: URL?
    private var apiKey = ""

    private static let lastTokenKey = "snoozestack_push_token"
    private static let lastUserKey = "snoozestack_push_user"

    private init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    private func configure(url: String, apiKey: String) {
        var base = url
        while base.hasSuffix("/") { base.removeLast() }
        lock.lock()
        defer { lock.unlock() }
        endpoint = URL(string: "\(base)/push/v1/devices")
        self.apiKey = apiKey
    }

    // MARK: - Registration

    /// Registers the token from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    ///
    /// Safe — and expected — to call on every launch: tokens change on
    /// reinstall and on restore-to-a-new-device, and a repeat registration of
    /// an unchanged token for an unchanged user is skipped without a request.
    public func register(deviceToken: Data) async throws {
        try await register(token: deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    /// Registers a hex-encoded token directly.
    public func register(token: String) async throws {
        #if targetEnvironment(simulator)
        throw PushError.simulatorUnsupported
        #else
        let (endpoint, apiKey) = try current()
        let accessToken = await accessTokenProvider?()
        let userId = accessToken.flatMap(Self.subject)

        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.lastTokenKey) == token,
           defaults.string(forKey: Self.lastUserKey) == (userId ?? "") {
            return
        }

        var body: [String: Any] = [
            "token": token,
            "environment": Self.environment.rawValue,
            "platform": "ios",
        ]
        if let bundleId = Bundle.main.bundleIdentifier { body["bundle_id"] = bundleId }
        if let locale = Locale.preferredLanguages.first { body["locale"] = locale }

        try await send(
            method: "POST",
            endpoint: endpoint,
            apiKey: apiKey,
            accessToken: accessToken,
            body: body
        )
        defaults.set(token, forKey: Self.lastTokenKey)
        defaults.set(userId ?? "", forKey: Self.lastUserKey)
        #endif
    }

    /// Unregisters the device — call on sign-out. Does nothing if this install
    /// never registered.
    public func unregister() async throws {
        let (endpoint, apiKey) = try current()
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: Self.lastTokenKey) else { return }
        try await send(
            method: "DELETE",
            endpoint: endpoint,
            apiKey: apiKey,
            accessToken: await accessTokenProvider?(),
            body: ["token": token]
        )
        defaults.removeObject(forKey: Self.lastTokenKey)
        defaults.removeObject(forKey: Self.lastUserKey)
    }

    // MARK: - Environment

    /// The APNs environment this build belongs to, read from the
    /// `aps-environment` entitlement in the embedded provisioning profile.
    ///
    /// `#if DEBUG` is the wrong test: TestFlight builds are release builds and
    /// live in production, while a release build run from Xcode is still
    /// sandbox. App Store builds carry no provisioning profile at all, which is
    /// why a missing profile means production.
    public static let environment: Environment = {
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            // The profile is a CMS blob with a plain-text plist inside it.
            let text = String(data: data, encoding: .isoLatin1),
            let range = text.range(of: "<key>aps-environment</key>")
        else {
            return .production
        }
        let tail = text[range.upperBound...]
        guard
            let open = tail.range(of: "<string>"),
            let close = tail.range(of: "</string>")
        else {
            return .production
        }
        let value = tail[open.upperBound..<close.lowerBound]
        return value == "development" ? .sandbox : .production
    }()

    // MARK: - Internals

    private func current() throws -> (URL, String) {
        lock.lock()
        defer { lock.unlock() }
        guard let endpoint, !apiKey.isEmpty else { throw PushError.notConfigured }
        return (endpoint, apiKey)
    }

    private func send(
        method: String,
        endpoint: URL,
        apiKey: String,
        accessToken: String?,
        body: [String: Any]
    ) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The user's token, not a second slot for the api key: it is the only
        // thing that may bind this device to a user id.
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw PushError.server(status: status, message: message)
        }
    }

    /// The `sub` claim of an access token, read locally to notice when the
    /// signed-in user changed. Never trusted for anything — the server verifies
    /// the token itself.
    private static func subject(of jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard
            let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json["sub"] as? String
    }
}
