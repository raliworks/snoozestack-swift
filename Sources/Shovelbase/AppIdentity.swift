// Client identity API for a project's own hosted application — magic link,
// OAuth, sessions and sign-out (#101). Mirrors sdk/src/app-identity.js
// exactly (same state machine, same error taxonomy, same wire shapes) —
// see ../../../docs/app-identity-client-contract.md for the shared,
// documented contract both SDKs implement, and that file's own header
// comment for why the browser/app handoff (magic-link click-through, OAuth
// provider redirect) is safe with no local state.
//
// A separate, project-scoped end-user population from `.auth` (GoTrue) —
// not an extension of it. There is deliberately no signUp,
// signInWithPassword, resetPasswordForEmail, confirm, or invite anywhere in
// this file.
//
// A lock-guarded class rather than an actor — matches ShovelbasePush.swift's
// own shape (NSLock-guarded mutable state) so state (`.state`/`.session`/
// `.user`) reads synchronously, the same as the JS SDK's getters, rather
// than needing `await` for a plain property read.
import Foundation
#if canImport(Security)
  import Security
#endif

// MARK: - State machine

/// The application-identity state machine. See
/// ../../../docs/app-identity-client-contract.md for the full transition
/// table and rationale.
public enum IdentityState: Sendable, Equatable {
  /// No session. The starting state, and where `signOut()` and a failed
  /// completion land.
  case anonymous
  /// A magic-link was requested, or an OAuth flow was started — waiting on
  /// the user to click through (magic-link) or the provider to redirect
  /// back (OAuth).
  case pending
  /// A valid session is held; `session`/`user` are populated.
  case authenticated
  /// A session was held but its refresh token is no longer valid (revoked,
  /// or genuinely expired). Reported once, then the session is anonymous.
  case expired
}

// MARK: - Error taxonomy

public enum ShovelbaseIdentityErrorCode: String, Sendable {
  case invalidRedirect = "invalid_redirect"
  case rateLimited = "rate_limited"
  case invalidOrExpiredLink = "invalid_or_expired_link"
  case invalidOrExpiredSession = "invalid_or_expired_session"
  case oauthDenied = "oauth_denied"
  case missingCode = "missing_code"
  case oauthFailed = "oauth_failed"
  case networkError = "network_error"
  case notConfigured = "not_configured"
  case serverError = "server_error"
}

/// Every throw from ``ShovelbaseIdentity`` is one of these. See
/// ../../../docs/app-identity-client-contract.md's error-taxonomy table for
/// the full server-response-to-code mapping.
public struct ShovelbaseIdentityError: Error, LocalizedError, Sendable {
  public let code: ShovelbaseIdentityErrorCode
  public let status: Int?
  public let message: String

  public init(code: ShovelbaseIdentityErrorCode, status: Int? = nil, message: String) {
    self.code = code
    self.status = status
    self.message = message
  }

  public var errorDescription: String? { message }
}

// MARK: - Session / user

public struct IdentitySession: Codable, Sendable, Equatable {
  public let sessionToken: String
  public let refreshToken: String
  public let sessionExpiresAt: String
  public let refreshExpiresAt: String

  public init(sessionToken: String, refreshToken: String, sessionExpiresAt: String, refreshExpiresAt: String) {
    self.sessionToken = sessionToken
    self.refreshToken = refreshToken
    self.sessionExpiresAt = sessionExpiresAt
    self.refreshExpiresAt = refreshExpiresAt
  }
}

public struct IdentityUser: Codable, Sendable, Equatable {
  public let id: String
  public let email: String

  public init(id: String, email: String) {
    self.id = id
    self.email = email
  }
}

public struct MagicLinkResult: Sendable {
  public let user: IdentityUser
  public let isNewUser: Bool
  public let redirectTo: String?
}

public struct OAuthResult: Sendable {
  public let user: IdentityUser
  public let isNewUser: Bool
}

// MARK: - Storage

/// Where ``ShovelbaseIdentity`` persists the current session between
/// launches. Default is ``KeychainIdentityStorage``.
public protocol ShovelbaseIdentityStorage: Sendable {
  func read(key: String) -> Data?
  func write(key: String, value: Data)
  func remove(key: String)
}

/// Keychain-backed session storage — the platform-appropriate default.
/// `kSecAttrAccessibleAfterFirstUnlock`: readable in the background (a
/// refresh can happen while the app isn't in the foreground), but not
/// before the device's first unlock after boot.
public final class KeychainIdentityStorage: ShovelbaseIdentityStorage, @unchecked Sendable {
  private let service: String

  public init(service: String = "com.shovelbase.identity") {
    self.service = service
  }

  public func read(key: String) -> Data? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return data
  }

  public func write(key: String, value: Data) {
    remove(key: key)
    var attributes = baseQuery(for: key)
    attributes[kSecValueData as String] = value
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(attributes as CFDictionary, nil)
  }

  public func remove(key: String) {
    SecItemDelete(baseQuery(for: key) as CFDictionary)
  }

  private func baseQuery(for key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}

// MARK: - Identity client

/// Client identity API for a project's own hosted application — magic link,
/// OAuth, sessions and sign-out.
///
///     let identity = ShovelbaseIdentity(url: projectURL, apiKey: anonKey)
///     try await identity.requestMagicLink(email: email, redirectTo: callbackURL)
///     // ... user clicks the emailed link, app opens on callbackURL?token=... ...
///     let result = try await identity.completeMagicLink(token: token)
public final class ShovelbaseIdentity: @unchecked Sendable {
  public struct Options: Sendable {
    /// "default" (live), "dev", or "preview:<name>" — must match the
    /// namespace `shovelbase auth push` configured redirect_urls/providers
    /// for. Defaults to "default".
    public var namespace: String
    public var storage: any ShovelbaseIdentityStorage
    /// Auto-refresh the session shortly before it expires. Defaults to true.
    public var autoRefresh: Bool

    public init(namespace: String = "default", storage: any ShovelbaseIdentityStorage = KeychainIdentityStorage(), autoRefresh: Bool = true) {
      self.namespace = namespace
      self.storage = storage
      self.autoRefresh = autoRefresh
    }
  }

  private let endpoint: URL
  private let apiKey: String
  private let namespace: String
  private let storage: any ShovelbaseIdentityStorage
  private let storageKey: String
  private let autoRefresh: Bool
  private let urlSession: URLSession

  private let lock = NSLock()
  private var _state: IdentityState = .anonymous
  private var _session: IdentitySession?
  private var _user: IdentityUser?
  private var listeners: [UUID: @Sendable (IdentityState, IdentitySession?, IdentityUser?) -> Void] = [:]
  private var refreshTask: Task<Void, Never>?
  private var inFlightMagicLink: [String: Task<MagicLinkResult, Error>] = [:]
  private var inFlightOAuth: Task<OAuthResult, Error>?

  /// Current state: `.anonymous` | `.pending` | `.authenticated` | `.expired`.
  public var state: IdentityState { withLock { _state } }

  /// The current session, or nil.
  public var session: IdentitySession? { withLock { _session } }

  /// The signed-in application user, or nil.
  public var user: IdentityUser? { withLock { _user } }

  public init(url: String, apiKey: String, options: Options = .init(), urlSession: URLSession = .shared) {
    var base = url
    while base.hasSuffix("/") { base.removeLast() }
    guard let endpoint = URL(string: "\(base)/auth") else {
      preconditionFailure("ShovelbaseIdentity(url:) requires a valid project URL")
    }
    self.endpoint = endpoint
    self.apiKey = apiKey
    self.namespace = options.namespace
    self.storage = options.storage
    self.storageKey = "sb-identity:\(base):\(options.namespace)"
    self.autoRefresh = options.autoRefresh
    self.urlSession = urlSession
    loadStoredSession()
    scheduleRefreshIfNeeded()
  }

  deinit {
    refreshTask?.cancel()
  }

  /// Subscribes to state changes. Called once immediately with the current
  /// state, then again on every transition. Call the returned closure to
  /// unsubscribe.
  @discardableResult
  public func onStateChange(_ listener: @escaping @Sendable (IdentityState, IdentitySession?, IdentityUser?) -> Void) -> () -> Void {
    let id = UUID()
    let snapshot: (IdentityState, IdentitySession?, IdentityUser?) = withLock {
      listeners[id] = listener
      return (_state, _session, _user)
    }
    listener(snapshot.0, snapshot.1, snapshot.2)
    return { [weak self] in
      guard let self else { return }
      self.withLock { _ = self.listeners.removeValue(forKey: id) }
    }
  }

  // MARK: Magic link

  /// Requests a magic-link email. Resolves once `redirectTo` checks out —
  /// never reveals whether `email` has an account.
  public func requestMagicLink(email: String, redirectTo: String) async throws {
    let _: OkBody = try await post("/magic-link", body: ["email": email, "redirect_to": redirectTo, "namespace": namespace])
    setState(.pending)
  }

  /// Completes a magic-link sign-in. Single-use: a second call for the same
  /// token (e.g. a duplicate deep-link delivery) returns the first call's
  /// own result/error instead of hitting the server again.
  public func completeMagicLink(token: String) async throws -> MagicLinkResult {
    // withLock() rather than bare lock()/unlock(): calling those directly
    // from an `async` function is flagged unavailable (an error under
    // Swift 6) since a lock held across a suspension point is a deadlock
    // risk — routing through a synchronous helper keeps every hold of the
    // lock itself non-suspending, same as the rest of this file's locking.
    let task: Task<MagicLinkResult, Error> = withLock {
      if let existing = inFlightMagicLink[token] { return existing }
      let task = Task { try await self.performMagicLinkVerify(token: token) }
      inFlightMagicLink[token] = task
      return task
    }
    defer { withLock { inFlightMagicLink[token] = nil } }
    return try await task.value
  }

  private func performMagicLinkVerify(token: String) async throws -> MagicLinkResult {
    setState(.pending)
    do {
      let payload: MagicLinkVerifyPayload = try await post("/magic-link/verify", body: ["token": token, "namespace": namespace])
      let user = IdentityUser(id: payload.user.id, email: payload.user.email)
      applySession(
        IdentitySession(
          sessionToken: payload.sessionToken, refreshToken: payload.refreshToken,
          sessionExpiresAt: payload.sessionExpiresAt, refreshExpiresAt: payload.refreshExpiresAt
        ),
        user: user
      )
      return MagicLinkResult(user: user, isNewUser: payload.isNewUser, redirectTo: payload.redirectTo)
    } catch {
      setState(.anonymous)
      throw error
    }
  }

  // MARK: OAuth

  /// Builds the `.../oauth/<provider>/start` URL (apikey and redirect_to
  /// travel as query params — this route is a plain browser/webview
  /// navigation, not a fetch). Open it with `ASWebAuthenticationSession` or
  /// `UIApplication.open(_:)`; the provider redirects back to `redirectTo`.
  public func startOAuth(provider: String, redirectTo: String) -> URL {
    var components = URLComponents(url: endpoint.appendingPathComponent("oauth/\(provider)/start"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "apikey", value: apiKey),
      URLQueryItem(name: "redirect_to", value: redirectTo),
      URLQueryItem(name: "namespace", value: namespace),
    ]
    setState(.pending)
    guard let url = components.url else {
      preconditionFailure("ShovelbaseIdentity.startOAuth produced an invalid URL")
    }
    return url
  }

  /// Completes an OAuth sign-in from the `redirectTo` URL your app's deep
  /// link / universal link handler received — the session travels in the
  /// URL **fragment** (see the contract doc for why). Single-use per
  /// callback the same way ``completeMagicLink(token:)`` is.
  public func completeOAuthCallback(url: URL) async throws -> OAuthResult {
    guard let fragment = url.fragment, !fragment.isEmpty else {
      throw ShovelbaseIdentityError(code: .notConfigured, message: "No OAuth callback fragment in the given URL")
    }
    let task: Task<OAuthResult, Error> = withLock {
      if let existing = inFlightOAuth { return existing }
      let task = Task { try await self.performOAuthCallback(fragment: fragment) }
      inFlightOAuth = task
      return task
    }
    defer { withLock { inFlightOAuth = nil } }
    return try await task.value
  }

  private func performOAuthCallback(fragment: String) async throws -> OAuthResult {
    setState(.pending)
    do {
      let params = Self.parseFragment(fragment)
      if let errorCode = params["error"] {
        throw Self.errorFromOAuthFragment(errorCode)
      }
      guard params["ok"] == "true",
        let sessionToken = params["session_token"],
        let refreshToken = params["refresh_token"],
        let sessionExpiresAt = params["session_expires_at"],
        let refreshExpiresAt = params["refresh_expires_at"],
        let userId = params["user_id"],
        let email = params["email"]
      else {
        throw ShovelbaseIdentityError(code: .serverError, message: "The OAuth callback fragment was missing the expected fields")
      }
      let user = IdentityUser(id: userId, email: email)
      applySession(
        IdentitySession(sessionToken: sessionToken, refreshToken: refreshToken, sessionExpiresAt: sessionExpiresAt, refreshExpiresAt: refreshExpiresAt),
        user: user
      )
      return OAuthResult(user: user, isNewUser: params["is_new_user"] == "true")
    } catch {
      setState(.anonymous)
      throw error
    }
  }

  // MARK: Refresh / sign-out

  /// Rotates the session from the stored refresh token. Moves to `.expired`
  /// (and clears storage) if the refresh token is invalid or revoked.
  @discardableResult
  public func refresh() async throws -> IdentitySession {
    guard let refreshToken = session?.refreshToken else {
      throw ShovelbaseIdentityError(code: .notConfigured, message: "No session to refresh")
    }
    do {
      let payload: SessionPayload = try await post("/session", body: ["refresh_token": refreshToken, "namespace": namespace])
      let newSession = IdentitySession(
        sessionToken: payload.sessionToken, refreshToken: payload.refreshToken,
        sessionExpiresAt: payload.sessionExpiresAt, refreshExpiresAt: payload.refreshExpiresAt
      )
      applySession(newSession, user: user)
      return newSession
    } catch let error as ShovelbaseIdentityError {
      if error.code == .invalidOrExpiredSession {
        clear(state: .expired)
      }
      throw error
    }
  }

  /// Signs out. Best-effort revoke on the server; clears local state
  /// unconditionally either way (the route is idempotent/uniform by design
  /// — see sign-out/route.ts's own comment — so a network failure here
  /// shouldn't trap the user signed in on their own device).
  public func signOut() async {
    if let token = session?.sessionToken ?? session?.refreshToken {
      let _: OkBody? = try? await post("/sign-out", body: ["token": token, "namespace": namespace])
    }
    clear(state: .anonymous)
  }

  // MARK: - Internals

  /// Every hold of `lock` routes through here (a plain synchronous
  /// function) rather than bare `lock()`/`unlock()` calls, so the lock is
  /// never held across a suspension point — see completeMagicLink's own
  /// comment for why that specifically matters for an `async` caller.
  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private func setState(_ newState: IdentityState) {
    typealias Listener = @Sendable (IdentityState, IdentitySession?, IdentityUser?) -> Void
    let broadcast: (state: IdentityState, session: IdentitySession?, user: IdentityUser?, listeners: [Listener])? = withLock {
      guard _state != newState else { return nil }
      _state = newState
      return (_state, _session, _user, Array(listeners.values))
    }
    guard let broadcast else { return }
    for listener in broadcast.listeners { listener(broadcast.state, broadcast.session, broadcast.user) }
  }

  private func applySession(_ newSession: IdentitySession, user newUser: IdentityUser?) {
    withLock {
      _session = newSession
      _user = newUser
    }
    persist(newSession, user: newUser)
    setState(.authenticated)
    scheduleRefreshIfNeeded()
  }

  private func clear(state newState: IdentityState) {
    withLock {
      _session = nil
      _user = nil
      refreshTask?.cancel()
      refreshTask = nil
    }
    storage.remove(key: storageKey)
    setState(newState)
  }

  private func persist(_ session: IdentitySession, user: IdentityUser?) {
    guard let data = try? JSONEncoder().encode(StoredState(session: session, user: user)) else { return }
    storage.write(key: storageKey, value: data)
  }

  private func loadStoredSession() {
    guard let data = storage.read(key: storageKey),
      let stored = try? JSONDecoder().decode(StoredState.self, from: data)
    else { return }
    // Optimistic: trust the stored session until proven otherwise (a
    // refresh, or a 401 from an authenticated call) rather than spending a
    // network round trip on every launch just to confirm it.
    guard let refreshExpiresAt = Self.parseDate(stored.session.refreshExpiresAt), refreshExpiresAt > Date() else {
      storage.remove(key: storageKey)
      return
    }
    _state = .authenticated
    _session = stored.session
    _user = stored.user
  }

  private func scheduleRefreshIfNeeded() {
    refreshTask?.cancel()
    refreshTask = nil
    guard autoRefresh, let session, let expiresAt = Self.parseDate(session.sessionExpiresAt) else { return }
    // Refresh well before expiry so a call in flight doesn't race the
    // token's own expiry.
    let delay = max(0, expiresAt.timeIntervalSinceNow - 60)
    refreshTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      _ = try? await self?.refresh()
    }
  }

  private func post<Response: Decodable>(_ path: String, body: [String: Any]) async throws -> Response {
    var request = URLRequest(url: URL(string: endpoint.absoluteString + path)!)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await urlSession.data(for: request)
    } catch {
      throw ShovelbaseIdentityError(code: .networkError, message: "Network request failed: \(error.localizedDescription)")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Request failed (\(status))"
      throw Self.errorFromResponse(status: status, message: message)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw ShovelbaseIdentityError(code: .serverError, status: status, message: "Unexpected response shape")
    }
  }

  private static func errorFromResponse(status: Int, message: String) -> ShovelbaseIdentityError {
    switch status {
    case 429:
      return ShovelbaseIdentityError(code: .rateLimited, status: status, message: message)
    case 404:
      return ShovelbaseIdentityError(code: .invalidOrExpiredLink, status: status, message: message)
    case 401:
      return ShovelbaseIdentityError(code: .invalidOrExpiredSession, status: status, message: message)
    case 400 where message.lowercased().contains("redirect"):
      return ShovelbaseIdentityError(code: .invalidRedirect, status: status, message: message)
    default:
      return ShovelbaseIdentityError(code: .serverError, status: status, message: message)
    }
  }

  // Fragment error codes the oauth callback route emits (see
  // oauth/[provider]/callback/route.ts): "missing_code" and
  // "oauth_failed"/"server_error" are ours; anything else is the
  // provider's own `error` query param passed straight through (e.g.
  // "access_denied"), surfaced uniformly as .oauthDenied.
  private static func errorFromOAuthFragment(_ code: String) -> ShovelbaseIdentityError {
    switch code {
    case "missing_code":
      return ShovelbaseIdentityError(code: .missingCode, message: "The OAuth callback had no authorization code")
    case "oauth_failed":
      return ShovelbaseIdentityError(code: .oauthFailed, message: "The OAuth sign-in failed")
    case "server_error":
      return ShovelbaseIdentityError(code: .serverError, message: "The OAuth sign-in failed (server error)")
    default:
      return ShovelbaseIdentityError(code: .oauthDenied, message: "The OAuth provider declined the request: \(code)")
    }
  }

  private static func parseFragment(_ fragment: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in fragment.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
      let value = String(parts[1]).replacingOccurrences(of: "+", with: " ")
      result[key] = value.removingPercentEncoding ?? value
    }
    return result
  }

  private static func parseDate(_ isoString: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: isoString) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: isoString)
  }
}

// MARK: - Wire shapes (see ../../../docs/app-identity-client-contract.md)

private struct OkBody: Decodable { let ok: Bool }
private struct ErrorBody: Decodable { let error: String }

private struct UserPayload: Decodable {
  let id: String
  let email: String
}

private struct SessionPayload: Decodable {
  let ok: Bool
  let sessionToken: String
  let refreshToken: String
  let sessionExpiresAt: String
  let refreshExpiresAt: String

  enum CodingKeys: String, CodingKey {
    case ok
    case sessionToken = "session_token"
    case refreshToken = "refresh_token"
    case sessionExpiresAt = "session_expires_at"
    case refreshExpiresAt = "refresh_expires_at"
  }
}

private struct MagicLinkVerifyPayload: Decodable {
  let ok: Bool
  let user: UserPayload
  let isNewUser: Bool
  let redirectTo: String?
  let sessionToken: String
  let refreshToken: String
  let sessionExpiresAt: String
  let refreshExpiresAt: String

  enum CodingKeys: String, CodingKey {
    case ok, user
    case isNewUser = "is_new_user"
    case redirectTo = "redirect_to"
    case sessionToken = "session_token"
    case refreshToken = "refresh_token"
    case sessionExpiresAt = "session_expires_at"
    case refreshExpiresAt = "refresh_expires_at"
  }
}

private struct StoredState: Codable {
  let session: IdentitySession
  let user: IdentityUser?
}
