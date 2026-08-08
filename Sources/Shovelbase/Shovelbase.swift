// Shovelbase — Swift client for shovelbase projects.
//
// shovelbase runs the standard backend services (PostgREST, GoTrue, storage-api,
// edge-runtime), so this client IS the upstream client API surface, re-exported
// with shovelbase defaults plus signals, feature flags and push:
//
//     import Shovelbase
//
//     let shovelbase = Shovelbase.createClient(
//         url: "http://<host>/sb/<project-ref>",   // SHOVELBASE_URL from the portal
//         key: "<SHOVELBASE_ANON_KEY>"
//     )
//
//     let clubs: [Club] = try await shovelbase.from("clubs").select().execute().value
//     try await shovelbase.auth.signIn(email: email, password: password)     // auth
//     try await shovelbase.storage.from("avatars").upload(path, data: data)  // storage
//     let reply = try await shovelbase.functions.invoke("kyd-golf-chat")     // edge functions
//     shovelbase.signals.track("signup", properties: ["plan": "pro"])        // signals
//     if await shovelbase.flags.isEnabled("new-checkout") { … }              // feature flags
//     try await shovelbase.push.register(deviceToken: token)                 // push notifications
//
// Everything the upstream client exports is re-exported here, so types and
// helpers (Session, User, PostgrestError, …) come from the same `import Shovelbase`.
// The upstream `Supabase*`-branded types are also surfaced under shovelbase
// names (e.g. `ShovelbaseClient`, `ShovelbaseClientOptions`) — prefer those.
//
// (Swift's `@_exported import` is all-or-nothing, so the upstream `Supabase*`
// names stay visible alongside the aliases; they can't be hidden without
// dropping the whole re-exported surface.)
//
// Note: realtime subscriptions (`.channel()`) are not supported by shovelbase
// yet; everything else behaves exactly like the upstream client.
import Foundation
@_exported import Supabase
@_exported import ShovelbaseSignals
@_exported import ShovelbaseFlags
@_exported import ShovelbasePush

/// The shovelbase client. Alias of the upstream client type; every instance
/// gains `.analytics` and `.flags` via the extension below. Prefer this name.
public typealias ShovelbaseClient = SupabaseClient

/// Options for ``Shovelbase/createClient(url:key:options:analytics:flags:)``.
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
    /// Also configures `ShovelbaseSignals.shared`, `ShovelbaseFlags.shared`
    /// and `ShovelbasePush.shared` against the same project, so
    /// `client.signals.track(…)`, `client.flags.isEnabled(…)` and
    /// `client.push.register(…)` work immediately; `signals` tunes event
    /// batching (flush interval, batch size) and `flags` the snapshot cache.
    public static func createClient(
        url: String,
        key: String,
        options: ShovelbaseClientOptions = .init(),
        signals signalsOptions: ShovelbaseSignals.Options = .init(),
        flags flagsOptions: ShovelbaseFlags.Options = .init()
    ) -> ShovelbaseClient {
        var base = url
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, !key.isEmpty, let projectURL = URL(string: base) else {
            preconditionFailure("Shovelbase.createClient(url:key:) requires the project URL and an API key")
        }
        ShovelbaseSignals.configure(url: base, apiKey: key, options: signalsOptions)
        ShovelbaseFlags.configure(url: base, apiKey: key, options: flagsOptions)
        ShovelbasePush.configure(url: base, apiKey: key)

        // A third-party `accessToken` provider replaces the auth client
        // entirely (reading `.auth` on such a client is a runtime issue), so
        // there is no session storage to wrap.
        guard options.auth.accessToken == nil else {
            // That provider *is* the session here, so push registration takes
            // the user's identity from it too.
            if let provider = options.auth.accessToken {
                ShovelbasePush.shared.accessTokenProvider = { try? await provider() }
            }
            return ShovelbaseClient(supabaseURL: projectURL, supabaseKey: key, options: options)
        }

        // Wrap session storage so a private-relay email resolved by
        // `auth.signInWithIdTokenResolvingPrivateRelay(credentials:)` survives
        // token refreshes and relaunches.
        let relayStorage = PrivateRelayEmailStorage(wrapping: options.auth.storage)
        let client = ShovelbaseClient(
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

    /// Feature flags toggled on the portal's Analytics → Feature Flags page.
    /// Alias for `ShovelbaseFlags.shared` (configured by
    /// `Shovelbase.createClient`).
    public var flags: ShovelbaseFlags { ShovelbaseFlags.shared }

    /// Push notification registration. Alias for `ShovelbasePush.shared`
    /// (configured by `Shovelbase.createClient`, including the access-token
    /// provider that binds a device to the signed-in user).
    ///
    /// There is no send method: pushes are sent server-side, off a queue
    /// trigger, because a client that could enqueue one could notify anybody.
    public var push: ShovelbasePush { ShovelbasePush.shared }
}
