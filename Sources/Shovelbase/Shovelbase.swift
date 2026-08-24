// Shovelbase — Swift client for shovelbase projects.
//
// shovelbase runs GoTrue + storage-api + edge-runtime — no PostgREST as of
// #123 (see ../../../docs/migrations/postgrest-removal.md) — so this client
// is the upstream client's auth/storage/functions API surface, re-exported
// with shovelbase defaults plus signals and push:
//
//     import Shovelbase
//
//     let shovelbase = Shovelbase.createClient(
//         url: "http://<host>/sb/<project-ref>",   // SHOVELBASE_URL from the portal
//         key: "<SHOVELBASE_ANON_KEY>"
//     )
//
//     try await shovelbase.auth.signIn(email: email, password: password)     // auth
//     try await shovelbase.storage.from("avatars").upload(path, data: data)  // storage
//     let reply = try await shovelbase.functions.invoke("kyd-golf-chat")     // edge functions
//     shovelbase.signals.track("signup", properties: ["plan": "pro"])        // signals
//     try await shovelbase.push.register(deviceToken: token)                 // push notifications
//
// No `.from()`/`.schema()`/`.rpc()` — those were PostgREST's query builder,
// and PostgREST is gone (#123). `ShovelbaseClient` wraps the upstream client
// rather than aliasing it specifically so those three names are not on this
// type's surface at all: calling one is a compile error, with a message
// pointing at ../../../docs/migrations/postgrest-removal.md and the
// replacement (a committed function reading/writing Postgres directly over
// its own `SHOVELBASE_DB_URL`, invoked via `shovelbase.functions.invoke(...)`)
// — see the `@available(*, unavailable)` overloads below. Mirrors
// `disableQueryBuilder()` in shovelbase-js (sdk/src/index.js) in spirit, not
// literally: Swift can enforce this at compile time, where JS — dynamically
// typed at the call site — only gets a runtime throw.
//
// Everything else the upstream client exports is re-exported here, so types
// and helpers (Session, User, …) come from the same `import Shovelbase`.
// The upstream `Supabase*`-branded types are also surfaced under shovelbase
// names (e.g. `ShovelbaseClientOptions`) — prefer those.
//
// (Swift's `@_exported import` is all-or-nothing, so the upstream `Supabase*`
// names — including the raw `SupabaseClient` class, whose `.from`/`.schema`/
// `.rpc` are still there — stay visible alongside the aliases; they can't be
// hidden without dropping the whole re-exported surface. `ShovelbaseClient`
// is the supported entry point; reaching for `SupabaseClient` directly to get
// the query builder back is exactly the kind of thing this file is refusing.)
//
// Note: realtime subscriptions (`.channel()`) are not supported by shovelbase
// yet; everything else behaves exactly like the upstream client.
import Foundation
@_exported import Supabase
@_exported import ShovelbaseSignals
@_exported import ShovelbasePush

/// The shovelbase client. Wraps the upstream `SupabaseClient` — see this
/// file's header comment for why it's a wrapper and not a `typealias` — and
/// gains `.analytics`/`.signals`/`.push` via the extensions below.
public final class ShovelbaseClient: Sendable {
    /// The wrapped upstream client. An escape hatch for upstream API this
    /// type doesn't forward — not where to reach for `.from`/`.schema`/
    /// `.rpc`; those are gone for good, see this file's header.
    public let base: SupabaseClient

    /// Magic link, OAuth, sessions and sign-out for this project's own
    /// hosted application (#101) — not `.auth` (GoTrue), a separate,
    /// project-scoped end-user population. See AppIdentity.swift.
    public let identity: ShovelbaseIdentity

    init(base: SupabaseClient, identity: ShovelbaseIdentity) {
        self.base = base
        self.identity = identity
    }

    /// The Auth client for managing user sessions and authentication.
    public var auth: AuthClient { base.auth }

    /// The Storage client for uploading, downloading, and managing files.
    public var storage: ShovelbaseStorageClient { base.storage }

    /// The Functions client for invoking edge functions. Wraps the upstream
    /// FunctionsClient so a call automatically carries `.identity`'s current
    /// session (`Authorization: Bearer <session_token>`) once one exists —
    /// see FunctionsClient.swift.
    public var functions: ShovelbaseFunctionsClient { ShovelbaseFunctionsClient(base: base.functions, identity: identity) }

    /// The Realtime client. Not supported by shovelbase yet — see this
    /// file's header comment.
    public var realtimeV2: RealtimeClientV2 { base.realtimeV2 }

    /// All active Realtime channels.
    public var channels: [RealtimeChannelV2] { base.channels }

    /// The HTTP headers included in every request made by sub-clients.
    public var headers: [String: String] { base.headers }

    /// Creates a Realtime channel. Not supported by shovelbase yet — see
    /// this file's header comment.
    public func channel(
        _ name: String,
        options: @Sendable (inout RealtimeChannelConfig) -> Void = { _ in }
    ) -> RealtimeChannelV2 {
        base.channel(name, options: options)
    }

    /// Unsubscribes from and removes a Realtime channel.
    public func removeChannel(_ channel: RealtimeChannelV2) async {
        await base.removeChannel(channel)
    }

    /// Unsubscribes from and removes all active Realtime channels.
    public func removeAllChannels() async {
        await base.removeAllChannels()
    }

    /// Completes an OAuth/magic-link deep link. See the upstream
    /// `SupabaseClient.handle(_:)` doc for app-lifecycle wiring examples.
    public func handle(_ url: URL) {
        base.handle(url)
    }
}

// PostgREST's query-builder entry points on the upstream client — removed at
// the network layer (#123 — /rest/v1 404s at the portal) and, here, from
// `ShovelbaseClient`'s type surface entirely. Redeclaring the same names as
// `unavailable` turns a call into a compile error carrying this message,
// instead of either compiling into a request that 404s (the pre-#151 state)
// or a runtime throw a caller only hits by exercising the code path.
extension ShovelbaseClient {
    @available(
        *, unavailable,
        message: "shovelbase.from(...) was removed along with PostgREST — see docs/migrations/postgrest-removal.md. Query or write the database from a committed function (it already has SHOVELBASE_DB_URL) and call it with shovelbase.functions.invoke(...) instead."
    )
    public func from(_ table: String) -> Never { fatalError() }

    @available(
        *, unavailable,
        message: "shovelbase.schema(...) was removed along with PostgREST — see docs/migrations/postgrest-removal.md. Query or write the database from a committed function (it already has SHOVELBASE_DB_URL) and call it with shovelbase.functions.invoke(...) instead."
    )
    public func schema(_ schema: String) -> Never { fatalError() }

    @available(
        *, unavailable,
        message: "shovelbase.rpc(...) was removed along with PostgREST — see docs/migrations/postgrest-removal.md. Query or write the database from a committed function (it already has SHOVELBASE_DB_URL) and call it with shovelbase.functions.invoke(...) instead."
    )
    public func rpc(_ fn: String, params: some Encodable, count: CountOption? = nil) -> Never { fatalError() }

    @available(
        *, unavailable,
        message: "shovelbase.rpc(...) was removed along with PostgREST — see docs/migrations/postgrest-removal.md. Query or write the database from a committed function (it already has SHOVELBASE_DB_URL) and call it with shovelbase.functions.invoke(...) instead."
    )
    public func rpc(_ fn: String, count: CountOption? = nil) -> Never { fatalError() }
}

/// Options for ``Shovelbase/createClient(url:key:options:signals:)``.
/// Alias of the upstream client options. Prefer this name.
public typealias ShovelbaseClientOptions = SupabaseClientOptions

/// The storage client (`client.storage`). Alias of the upstream type.
public typealias ShovelbaseStorageClient = SupabaseStorageClient

/// Verbosity for the client's logger. Alias of the upstream type.
public typealias ShovelbaseLogLevel = SupabaseLogLevel

/// A logger the client emits diagnostics to. Alias of the upstream type.
public typealias ShovelbaseLogger = SupabaseLogger

/// A single log record produced by the client. Alias of the upstream type.
public typealias ShovelbaseLogMessage = SupabaseLogMessage

public enum Shovelbase {

    /// Creates a shovelbase client. `url` is your project URL
    /// (`http://<host>/sb/<ref>`), `key` the anon key (apps) or the
    /// service_role key (trusted servers only).
    ///
    /// Also configures `ShovelbaseSignals.shared` and `ShovelbasePush.shared`
    /// against the same project, so `client.signals.track(…)` and
    /// `client.push.register(…)` work immediately; `signals` tunes event
    /// batching (flush interval, batch size); `identity` tunes the
    /// application-identity client (namespace, session storage,
    /// auto-refresh — see `ShovelbaseIdentity.Options`).
    public static func createClient(
        url: String,
        key: String,
        options: ShovelbaseClientOptions = .init(),
        signals signalsOptions: ShovelbaseSignals.Options = .init(),
        identity identityOptions: ShovelbaseIdentity.Options = .init()
    ) -> ShovelbaseClient {
        var base = url
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, !key.isEmpty, let projectURL = URL(string: base) else {
            preconditionFailure("Shovelbase.createClient(url:key:) requires the project URL and an API key")
        }
        ShovelbaseSignals.configure(url: base, apiKey: key, options: signalsOptions)
        ShovelbasePush.configure(url: base, apiKey: key)
        let identity = ShovelbaseIdentity(url: base, apiKey: key, options: identityOptions)

        // A third-party `accessToken` provider replaces the auth client
        // entirely (reading `.auth` on such a client is a runtime issue), so
        // there is no session storage to wrap.
        guard options.auth.accessToken == nil else {
            // That provider *is* the session here, so push registration takes
            // the user's identity from it too.
            if let provider = options.auth.accessToken {
                ShovelbasePush.shared.accessTokenProvider = { try? await provider() }
            }
            return ShovelbaseClient(
                base: SupabaseClient(supabaseURL: projectURL, supabaseKey: key, options: options),
                identity: identity
            )
        }

        // Wrap session storage so a private-relay email resolved by
        // `auth.signInWithIdTokenResolvingPrivateRelay(credentials:)` survives
        // token refreshes and relaunches.
        let relayStorage = PrivateRelayEmailStorage(wrapping: options.auth.storage)
        let supabase = SupabaseClient(
            supabaseURL: projectURL,
            supabaseKey: key,
            options: ShovelbaseClientOptions(
                db: options.db,
                auth: .init(
                    storage: relayStorage,
                    redirectToURL: options.auth.redirectToURL,
                    storageKey: options.auth.storageKey,
                    flowType: options.auth.flowType,
                    encoder: options.auth.encoder,
                    decoder: options.auth.decoder,
                    autoRefreshToken: options.auth.autoRefreshToken,
                    emitLocalSessionAsInitialSession: options.auth.emitLocalSessionAsInitialSession
                ),
                global: options.global,
                functions: options.functions,
                realtime: options.realtime,
                storage: options.storage
            )
        )
        let client = ShovelbaseClient(base: supabase, identity: identity)
        PrivateRelayEmailStorage.register(relayStorage, for: client.auth)
        // Lets push.register() attach the current access token, so the server
        // can bind the device to the signed-in user. Weak: the shared push
        // object outlives any one client and must not keep it alive.
        ShovelbasePush.shared.accessTokenProvider = { [weak client] in
            guard let client else { return nil }
            return try? await client.auth.session.accessToken
        }
        return client
    }
}

extension ShovelbaseClient {
    /// Mixpanel-style event tracking (Signals), charted on the portal's Signals
    /// page. Alias for `ShovelbaseSignals.shared` (configured by
    /// `Shovelbase.createClient`).
    public var signals: ShovelbaseSignals { ShovelbaseSignals.shared }

    /// Deprecated alias of ``signals``.
    @available(*, deprecated, renamed: "signals")
    public var analytics: ShovelbaseSignals { ShovelbaseSignals.shared }

    /// Push notification registration. Alias for `ShovelbasePush.shared`
    /// (configured by `Shovelbase.createClient`, including the access-token
    /// provider that binds a device to the signed-in user).
    ///
    /// There is no send method: pushes are sent server-side, off a queue
    /// trigger, because a client that could enqueue one could notify anybody.
    public var push: ShovelbasePush { ShovelbasePush.shared }
}
