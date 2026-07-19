# shovelbase-swift

Swift client for [shovelbase](../README.md) projects on iOS, macOS, tvOS, and
watchOS — database queries, auth, storage, edge functions, analytics, and
feature flags.

The `Shovelbase` module is a full typed client for your shovelbase project —
database queries, auth, storage, and edge functions — plus Mixpanel-style
analytics and feature flags. Three library products:

- **`Shovelbase`** — the full client (`Shovelbase.createClient`, database,
  auth, storage, functions, `.analytics`, and `.flags`).
- **`ShovelbaseAnalytics`** — analytics only; a single dependency-free file, if
  you don't need the database/auth client.
- **`ShovelbaseFlags`** — feature flags only; a single dependency-free file.

## Install

The package is served as a git repo from `shovelbase.com` — it is **not** on
GitHub or any package index. In Xcode: **File → Add Package Dependencies…**,
paste

```
https://shovelbase.com/swift/shovelbase-swift.git
```

choose **Up to Next Major Version** from `0.2.0`, and add the `Shovelbase`
library to your app target. Or in a `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://shovelbase.com/swift/shovelbase-swift.git",
        from: "0.2.0"
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
    url: "https://<project-ref>.shovelbase.com",   // SHOVELBASE_URL
    key: "<SHOVELBASE_ANON_KEY>"
)

// Database (with row-level security)
let clubs: [Club] = try await shovelbase.from("clubs")
    .select().eq("in_bag", value: true).execute().value

// Auth
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

// Feature flags (toggled on the portal's Analytics → Feature Flags page)
if await shovelbase.flags.isEnabled("new-checkout") { /* … */ }
```

Supporting types (`Session`, `User`, query/error types, …) come from the same
`import Shovelbase`. Not supported yet: realtime subscriptions (`.channel()`).

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

### Feature-flag behavior

- Lookups never throw: the snapshot is cached for 60 s (tunable via the
  `flags:` parameter of `createClient`, or `ShovelbaseFlags.Options`
  standalone); offline they serve the last snapshot, and before the first
  fetch they return the fallback you pass (`isEnabled(_:fallback:)`).
- `getAll()` returns the whole snapshot, `refresh()` bypasses the cache, and
  `peek(_:fallback:)` reads the last-known value synchronously (for render
  paths that can't await).

Using flags without the client: add the `ShovelbaseFlags` product instead and
call `ShovelbaseFlags.configure(url:apiKey:)` at launch.
