// Private-relay email resolution for native ID-token sign-in.
//
// Apple's "Hide My Email" hands the app a relay address (`…@privaterelay.
// appleid.com`) in the `email` claim of the identity token. The claim is in
// every token Apple issues, but the `ASAuthorizationAppleIDCredential` object
// only carries the address on the *first* authorization, and the auth server
// only stores it if it had one to store — so a user created without it keeps
// an empty `user.email` on every session that follows, including refreshes.
//
// The identity token is the reliable read, so
// ``signInWithIdTokenResolvingPrivateRelay(credentials:)`` fills the gap from
// the token's own claim and remembers the address for the session's lifetime
// on the device.
import Foundation
import Supabase

extension Shovelbase {

    /// The `email` claim of an OIDC identity token, or `nil` when the token
    /// carries no (non-empty) claim.
    ///
    /// Apple drops the email from the credential object after the first
    /// authorization but keeps it in the JWT, so this is the reliable read on
    /// repeat sign-ins. The token is *not* verified here — the auth server
    /// does that when it exchanges the same token for a session, so only read
    /// the claim off a token a sign-in already accepted.
    public static func emailClaim(fromIdToken idToken: String) -> String? {
        let segments = idToken.components(separatedBy: ".")
        guard segments.count == 3,
              let payload = base64URLDecode(segments[1]),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let email = claims["email"] as? String,
              !email.isEmpty else {
            return nil
        }
        return email
    }

    /// JWT segments are base64url with padding stripped; `Data(base64Encoded:)`
    /// needs the standard alphabet and full padding restored.
    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

extension AuthClient {

    /// Signs in with an identity token, filling in an email the provider hid.
    ///
    /// Identical to `signInWithIdToken(credentials:)` except that when the
    /// session comes back without an email — what Sign in with Apple does for
    /// a user who chose **Hide My Email** — the `email` claim of `credentials
    /// .idToken` is used instead, so `session.user.email` is the relay
    /// address rather than `nil`:
    ///
    ///     let session = try await shovelbase.auth
    ///         .signInWithIdTokenResolvingPrivateRelay(
    ///             credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
    ///         )
    ///     session.user.email   // "…@privaterelay.appleid.com"
    ///
    /// The address is also remembered on the device, so later reads of
    /// `auth.session` / `auth.currentUser` — including the ones after a token
    /// refresh or an app relaunch, where the identity token is long gone —
    /// report it too. It is dropped on `signOut()`.
    ///
    /// That persistence needs the client to come from
    /// ``Shovelbase/createClient(url:key:options:signals:flags:)``; on a
    /// directly constructed client the returned session is still filled in,
    /// but only that value carries the email.
    ///
    /// The session's tokens are untouched: the auth server issues them from
    /// the record it holds, so a JWT for a user it has no email for still has
    /// no `email` claim, and anything reading the email server-side (RLS
    /// policies, edge functions, PostgREST) sees what the server stored.
    @discardableResult
    public func signInWithIdTokenResolvingPrivateRelay(
        credentials: OpenIDConnectCredentials
    ) async throws -> Session {
        var session = try await signInWithIdToken(credentials: credentials)

        guard session.user.email?.isEmpty != false,
              let claimed = Shovelbase.emailClaim(fromIdToken: credentials.idToken) else {
            return session
        }

        session.user.email = claimed
        PrivateRelayEmailStorage.registered(for: self)?.remember(claimed, forUserID: session.user.id)
        return session
    }
}

/// Wraps the auth client's local storage and puts a resolved private-relay
/// email back onto the stored session as it is read.
///
/// The auth client re-reads the session from storage on every access and
/// overwrites it on every token refresh, so patching on the way out is what
/// makes the email survive both — the stored blob itself is never rewritten,
/// and the remembered addresses live under their own key beside it.
final class PrivateRelayEmailStorage: AuthLocalStorage, @unchecked Sendable {

    /// Key the `userID: email` table is stored under, beside the session.
    private static let tableKey = "shovelbase.private-relay-emails"

    private let base: any AuthLocalStorage
    private let lock = NSLock()
    private var emails: [String: String]?
    /// The key the session blob was last seen under, so `remove` can tell a
    /// sign-out from the code verifier being cleaned up.
    private var sessionKey: String?

    init(wrapping base: any AuthLocalStorage) {
        self.base = base
    }

    // MARK: - AuthLocalStorage

    func store(key: String, value: Data) throws {
        try base.store(key: key, value: value)
    }

    func retrieve(key: String) throws -> Data? {
        guard let data = try base.retrieve(key: key) else { return nil }
        return resolved(data, key: key) ?? data
    }

    func remove(key: String) throws {
        try base.remove(key: key)
        lock.lock()
        let isSession = key == sessionKey
        lock.unlock()
        if isSession { forgetAll() }
    }

    // MARK: - Remembered addresses

    func remember(_ email: String, forUserID userID: UUID) {
        lock.lock()
        var table = loadedTableLocked()
        table[userID.uuidString.lowercased()] = email
        emails = table
        lock.unlock()
        try? base.store(key: Self.tableKey, value: JSONEncoder().encode(table))
    }

    private func forgetAll() {
        lock.lock()
        emails = [:]
        lock.unlock()
        try? base.remove(key: Self.tableKey)
    }

    /// The stored session with its user's email filled in, or `nil` when
    /// there is nothing to fill in. Works on the raw JSON so it stays correct
    /// whatever encoder the auth client stores sessions with.
    private func resolved(_ data: Data, key: String) -> Data? {
        guard var session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var user = session["user"] as? [String: Any],
              let userID = user["id"] as? String else {
            return nil
        }

        lock.lock()
        sessionKey = key
        let email = loadedTableLocked()[userID.lowercased()]
        lock.unlock()

        guard let email,
              (user["email"] as? String ?? "").isEmpty else {
            return nil
        }

        user["email"] = email
        session["user"] = user
        return try? JSONSerialization.data(withJSONObject: session)
    }

    /// Caller must hold `lock`.
    private func loadedTableLocked() -> [String: String] {
        if let emails { return emails }
        let stored = try? base.retrieve(key: Self.tableKey)
        let table = stored.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        emails = table
        return table
    }
}

extension PrivateRelayEmailStorage {

    /// Live storages by auth client, so
    /// ``AuthClient/signInWithIdTokenResolvingPrivateRelay(credentials:)`` can
    /// reach the one its client reads through. One entry per client, and
    /// clients are made once at launch.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var storages: [ObjectIdentifier: PrivateRelayEmailStorage] = [:]

        subscript(client: AuthClient) -> PrivateRelayEmailStorage? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storages[ObjectIdentifier(client)]
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                storages[ObjectIdentifier(client)] = newValue
            }
        }
    }

    private static let registry = Registry()

    static func register(_ storage: PrivateRelayEmailStorage, for client: AuthClient) {
        registry[client] = storage
    }

    static func registered(for client: AuthClient) -> PrivateRelayEmailStorage? {
        registry[client]
    }
}
