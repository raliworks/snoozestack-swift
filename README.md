# shovelbase-swift

Swift client for [shovelbase](../README.md) projects on iOS, macOS, tvOS, and
watchOS — database queries, auth, storage, edge functions, and analytics.

shovelbase runs the standard backend services (PostgREST, GoTrue, storage-api,
edge-runtime), so the `Shovelbase` module re-exports the complete
`supabase-swift` API pointed at your shovelbase project, and adds
Mixpanel-style analytics. Two library products:

- **`Shovelbase`** — the full client (`Shovelbase.createClient` + everything
  supabase-swift exports + `.analytics`).
- **`ShovelbaseAnalytics`** — analytics only; a single dependency-free file, if
  you don't need the database/auth client.

## Install

The package is served as a git repo from public S3 — it is **not** on GitHub
or any package index. In Xcode: **File → Add Package Dependencies…**, paste

```
https://shovelbase-packages.s3.us-west-2.amazonaws.com/swift/shovelbase-swift.git
```

choose **Up to Next Major Version** from `0.1.0`, and add the `Shovelbase`
library to your app target. Or in a `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://shovelbase-packages.s3.us-west-2.amazonaws.com/swift/shovelbase-swift.git",
        from: "0.1.0"
    ),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Shovelbase", package: "shovelbase-swift"),
    ]),
]
```

To release a new version: bump `VERSION`, run `../scripts/publish-sdks.sh
swift` (it commits the current `sdk-swift/` content to the hosted repo and
tags it — published versions are immutable), then update the dependency in
Xcode (*File → Packages → Update to Latest Package Versions*).

## Use

```swift
import Shovelbase

// Once, at launch (e.g. in your App init).
// URL + anon key: portal → Project Settings → API.
let shovelbase = Shovelbase.createClient(
    url: "http://<host>/sb/<project-ref>",   // SHOVELBASE_URL
    key: "<SHOVELBASE_ANON_KEY>"
)

// Database (PostgREST + RLS)
let clubs: [Club] = try await shovelbase.from("clubs")
    .select().eq("in_bag", value: true).execute().value

// Auth (GoTrue)
try await shovelbase.auth.signUp(email: email, password: password)
let user = try await shovelbase.auth.session.user

// Storage
try await shovelbase.storage.from("avatars")
    .upload("\(user.id).png", data: imageData)

// Edge functions
let reply: ChatReply = try await shovelbase.functions
    .invoke("kyd-golf-chat", options: .init(body: ["messages": messages]))

// Analytics (charted on the portal's Observability → Analytics page)
shovelbase.analytics.identify(user.id.uuidString)
shovelbase.analytics.track("signup", properties: ["plan": "pro"])
```

Everything supabase-swift exports (`Session`, `User`, `PostgrestError`, …)
comes from the same `import Shovelbase`. Not supported yet: realtime
subscriptions (`.channel()`).

### Analytics behavior

- `track` is fire-and-forget — it never throws and never blocks the caller.
- Events are persisted to disk, so they survive app kills.
- Batches flush every 10 s, at 20 queued events, and when the app is
  backgrounded (tunable via the `analytics:` parameter of `createClient`,
  or `ShovelbaseAnalytics.Options` standalone).
- Each event carries an `insert_id`, so a batch retried after a network
  timeout is never double-counted.
- Default properties sent with every event: `$os`, `$os_version`,
  `$app_version`, `$sdk`.
- Property values must be JSON-encodable; anything else is stringified.

Using analytics without the client: add the `ShovelbaseAnalytics` product
instead and call `ShovelbaseAnalytics.configure(url:apiKey:)` at launch.
