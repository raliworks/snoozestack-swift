// Snoozestack — Swift client for snoozestack projects.
//
//     import Snoozestack
//
//     let snoozestack = Snoozestack.createClient(
//         url: "https://<project-ref>.snoozestack.com",   // SNOOZESTACK_URL from the portal
//         key: "<SNOOZESTACK_ANON_KEY>"
//     )
//
//     try await snoozestack.identity.signInWithPassword(email: email, password: password)
//     let reply: Reply = try await snoozestack.functions.invoke("kyd-golf-chat")
//     snoozestack.signals.track("signup", properties: ["plan": "pro"])
//     try await snoozestack.push.register(deviceToken: token)
//
// As of 1.0 this package has no third-party dependencies (#209). It used to
// wrap the upstream supabase client, which is why the surface below is
// smaller than it once was:
//
//   .auth       removed — application identity replaces it. `.identity` is
//               the whole auth story: magic link, password, OAuth (including
//               native id-token sign-in), sessions, sign-out.
//   .storage    removed — storage access is mediated by your own functions.
//               Have a function return a signed URL and PUT to it directly.
//   .from()     removed with PostgREST itself (#123, see
//   .schema()   docs/migrations/postgrest-removal.md). Query or write the
//   .rpc()      database from a committed function — it already has
//               SNOOZESTACK_DB_URL — and call it via `functions.invoke`.
//   .base       removed — there is no wrapped client to reach past this one to.
//   realtime    never supported by snoozestack.
//
// These are gone, not deprecated: the package majored to 1.0 to say so, and
// SPM consumers pin versions, so nothing already shipped changes under them.
import Foundation
@_exported import SnoozestackSignals
@_exported import SnoozestackPush

/// The snoozestack client. Created by ``Snoozestack/createClient(url:key:signals:identity:)``.
public final class SnoozestackClient: Sendable {
    /// The resolved project base every service path is built from.
    public let url: String

    /// Magic link, password, OAuth, sessions and sign-out for this project's
    /// own hosted application (#101). See AppIdentity.swift.
    public let identity: SnoozestackIdentity

    /// Calling this project's functions. A call carries `identity`'s current
    /// session automatically — see FunctionsClient.swift.
    public let functions: SnoozestackFunctionsClient

    init(url: String, identity: SnoozestackIdentity, functions: SnoozestackFunctionsClient) {
        self.url = url
        self.identity = identity
        self.functions = functions
    }
}

public enum Snoozestack {

    /// Creates a snoozestack client. `url` is your project URL
    /// (`https://<ref>.snoozestack.com`), `key` the anon key (apps) or the
    /// service_role key (trusted servers only).
    ///
    /// Also configures `SnoozestackSignals.shared` and `SnoozestackPush.shared`
    /// against the same project, so `client.signals.track(…)` and
    /// `client.push.register(…)` work immediately. `signals` tunes event
    /// batching (flush interval, batch size); `identity` tunes the
    /// application-identity client (namespace, session storage,
    /// auto-refresh — see `SnoozestackIdentity.Options`).
    public static func createClient(
        url: String,
        key: String,
        signals signalsOptions: SnoozestackSignals.Options = .init(),
        identity identityOptions: SnoozestackIdentity.Options = .init()
    ) -> SnoozestackClient {
        var base = url
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, !key.isEmpty, URL(string: base) != nil else {
            preconditionFailure("Snoozestack.createClient(url:key:) requires the project URL and an API key")
        }
        SnoozestackSignals.configure(url: base, apiKey: key, options: signalsOptions)
        SnoozestackPush.configure(url: base, apiKey: key)

        let identity = SnoozestackIdentity(url: base, apiKey: key, options: identityOptions)
        let functions = SnoozestackFunctionsClient(url: base, key: key, identity: identity)
        let client = SnoozestackClient(url: base, identity: identity, functions: functions)

        // Lets push.register() attach the current session token, so the server
        // can bind the device to the signed-in user. Weak: the shared push
        // object outlives any one client and must not keep it alive.
        SnoozestackPush.shared.accessTokenProvider = { [weak client] in
            guard let client else { return nil }
            try? await client.identity.ensureFreshSession()
            return client.identity.session?.sessionToken
        }
        return client
    }
}

extension SnoozestackClient {
    /// Mixpanel-style event tracking (Signals), charted on the portal's Signals
    /// page. Alias for `SnoozestackSignals.shared` (configured by
    /// `Snoozestack.createClient`).
    public var signals: SnoozestackSignals { SnoozestackSignals.shared }

    /// Deprecated alias of ``signals``.
    @available(*, deprecated, renamed: "signals")
    public var analytics: SnoozestackSignals { SnoozestackSignals.shared }

    /// Push notification registration. Alias for `SnoozestackPush.shared`
    /// (configured by `Snoozestack.createClient`, including the token provider
    /// that binds a device to the signed-in user).
    ///
    /// There is no send method: pushes are sent server-side, off a queue
    /// trigger, because a client that could enqueue one could notify anybody.
    public var push: SnoozestackPush { SnoozestackPush.shared }
}
