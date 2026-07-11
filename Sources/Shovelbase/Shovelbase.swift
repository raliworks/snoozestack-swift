// Shovelbase — Swift client for shovelbase projects.
//
// shovelbase runs the standard backend services (PostgREST, GoTrue, storage-api,
// edge-runtime), so this client IS the supabase-swift API surface, re-exported
// with shovelbase defaults plus analytics:
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
//
// Everything supabase-swift exports is re-exported here, so types and helpers
// (Session, User, PostgrestError, …) come from the same `import Shovelbase`.
//
// Note: realtime subscriptions (`.channel()`) are not supported by shovelbase
// yet; everything else behaves exactly like supabase-swift.
import Foundation
@_exported import Supabase
@_exported import ShovelbaseAnalytics

public enum Shovelbase {

    /// Creates a shovelbase client. `url` is your project URL
    /// (`http://<host>/sb/<ref>`), `key` the anon key (apps) or the
    /// service_role key (trusted servers only).
    ///
    /// Also configures `ShovelbaseAnalytics.shared` against the same project, so
    /// `client.analytics.track(…)` works immediately; `analytics` tunes event
    /// batching (flush interval, batch size).
    public static func createClient(
        url: String,
        key: String,
        options: SupabaseClientOptions = .init(),
        analytics analyticsOptions: ShovelbaseAnalytics.Options = .init()
    ) -> SupabaseClient {
        var base = url
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, !key.isEmpty, let projectURL = URL(string: base) else {
            preconditionFailure("Shovelbase.createClient(url:key:) requires the project URL and an API key")
        }
        ShovelbaseAnalytics.configure(url: base, apiKey: key, options: analyticsOptions)
        return SupabaseClient(supabaseURL: projectURL, supabaseKey: key, options: options)
    }
}

extension SupabaseClient {
    /// Mixpanel-style event tracking, charted on the portal's
    /// Observability → Analytics page. Alias for `ShovelbaseAnalytics.shared`
    /// (configured by `Shovelbase.createClient`).
    public var analytics: ShovelbaseAnalytics { ShovelbaseAnalytics.shared }
}
