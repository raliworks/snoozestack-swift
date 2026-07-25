// Shovelbase — Swift client for shovelbase projects.
//
// shovelbase runs the standard backend services (PostgREST, GoTrue, storage-api,
// edge-runtime), so this client IS the upstream client API surface, re-exported
// with shovelbase defaults plus analytics and feature flags:
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
//     shovelbase.analytics.track("signup", properties: ["plan": "pro"])      // analytics
//     if await shovelbase.flags.isEnabled("new-checkout") { … }              // feature flags
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
@_exported import ShovelbaseAnalytics
@_exported import ShovelbaseFlags

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
    /// Also configures `ShovelbaseAnalytics.shared` and `ShovelbaseFlags.shared`
    /// against the same project, so `client.analytics.track(…)` and
    /// `client.flags.isEnabled(…)` work immediately; `analytics` tunes event
    /// batching (flush interval, batch size) and `flags` the snapshot cache.
    public static func createClient(
        url: String,
        key: String,
        options: ShovelbaseClientOptions = .init(),
        analytics analyticsOptions: ShovelbaseAnalytics.Options = .init(),
        flags flagsOptions: ShovelbaseFlags.Options = .init()
    ) -> ShovelbaseClient {
        var base = url
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, !key.isEmpty, let projectURL = URL(string: base) else {
            preconditionFailure("Shovelbase.createClient(url:key:) requires the project URL and an API key")
        }
        ShovelbaseAnalytics.configure(url: base, apiKey: key, options: analyticsOptions)
        ShovelbaseFlags.configure(url: base, apiKey: key, options: flagsOptions)
        return ShovelbaseClient(supabaseURL: projectURL, supabaseKey: key, options: options)
    }
}

extension ShovelbaseClient {
    /// Mixpanel-style event tracking, charted on the portal's
    /// Observability → Analytics page. Alias for `ShovelbaseAnalytics.shared`
    /// (configured by `Shovelbase.createClient`).
    public var analytics: ShovelbaseAnalytics { ShovelbaseAnalytics.shared }

    /// Feature flags toggled on the portal's Analytics → Feature Flags page.
    /// Alias for `ShovelbaseFlags.shared` (configured by
    /// `Shovelbase.createClient`).
    public var flags: ShovelbaseFlags { ShovelbaseFlags.shared }
}
