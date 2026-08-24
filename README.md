# shovelbase-swift

Swift client for [shovelbase](../README.md) projects on iOS, macOS, tvOS, and
watchOS — auth, storage, edge functions, and signals. No client-side database
query builder (`.from()`/`.schema()`/`.rpc()` were removed with PostgREST —
see `../docs/migrations/postgrest-removal.md`): read or write the database
from a committed function instead, over its own `SHOVELBASE_DB_URL`. Calling
any of the three is a compile error pointing at that guide — `ShovelbaseClient`
wraps the upstream client rather than aliasing it specifically so they aren't
on its type surface (see `Shovelbase.swift`'s header comment).

The `Shovelbase` module is a full typed client for your shovelbase project —
auth, storage, and edge functions — plus Mixpanel-style signals. Two library
products:

- **`Shovelbase`** — the full client (`Shovelbase.createClient`, database,
  auth, storage, functions, and `.signals`).
- **`ShovelbaseSignals`** — event tracking only; a single dependency-free file,
  if you don't need the database/auth client. (`ShovelbaseAnalytics` remains as
  a deprecated alias product.)

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

// Auth
try await shovelbase.auth.signUp(email: email, password: password)
let user = try await shovelbase.auth.session.user

// Storage
try await shovelbase.storage.from("avatars")
    .upload("\(user.id).png", data: imageData)

// Edge functions
let reply: ChatReply = try await shovelbase.functions
    .invoke("kyd-golf-chat", options: .init(body: ["messages": messages]))

// Signals (event tracking; charted on the portal's Signals page)
shovelbase.signals.identify(user.id.uuidString)  // merges their anonymous history in
shovelbase.signals.track("signup", properties: ["plan": "pro"])
shovelbase.signals.reset()                        // on sign-out
```

Supporting types (`Session`, `User`, query/error types, …) come from the same
`import Shovelbase`. Not supported yet: realtime subscriptions (`.channel()`).
Removed for good: `.from()`/`.schema()`/`.rpc()` (PostgREST) — calling one is
a compile error with a pointer to the replacement pattern.

### Application identity (magic link, OAuth, sessions)

`.identity` is a separate, project-scoped end-user population from `.auth`
(GoTrue) — sign-in for your own hosted application's users, not shovelbase
operators. See `../docs/app-identity-client-contract.md` for the full state
machine and error taxonomy (shared with the JS SDK).

```swift
try await shovelbase.identity.requestMagicLink(
    email: email, redirectTo: "https://myapp.example.com/callback"
)
// ... user clicks the emailed link; your app opens on
//     https://myapp.example.com/callback?token=... ...
let result = try await shovelbase.identity.completeMagicLink(token: token)
result.user.email

// shovelbase.functions.invoke(...) automatically carries
// `.identity`'s session once one exists — no extra wiring needed.
let reply: ChatReply = try await shovelbase.functions.invoke("kyd-golf-chat", body: ["messages": messages])

await shovelbase.identity.signOut()
```

OAuth: `startOAuth(provider:redirectTo:)` returns the authorize URL to open
(`ASWebAuthenticationSession` or `UIApplication.open(_:)`); your app's
universal-link handler passes the resulting `redirectTo` URL to
`completeOAuthCallback(url:)`.

`shovelbase.identity.onStateChange { state, session, user in ... }` observes
`.anonymous` / `.pending` / `.authenticated` / `.expired` reactively.

### Sign in with Apple, and Hide My Email

Native apps sign in by ID token — pass the credential from
`ASAuthorizationController` straight through, and the user never leaves the
app. Use `signInWithIdTokenResolvingPrivateRelay` rather than
`signInWithIdToken`:

```swift
let session = try await shovelbase.auth.signInWithIdTokenResolvingPrivateRelay(
    credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
)
session.user.email   // "…@privaterelay.appleid.com", not nil
```

Apple hands the relay address to your app in the *identity token* on every
sign-in, but drops it from the credential object after the first
authorization — so a user whose record was created without it comes back from
plain `signInWithIdToken` with `user.email == nil`, on that sign-in and on
every one after it. The `ResolvingPrivateRelay` variant is the same call, plus:
it reads the token's `email` claim when the session comes back without one,
and remembers the address on the device so `auth.session` and
`auth.currentUser` still report it after a token refresh or a relaunch (it is
dropped on `signOut()`). Everything else is untouched.

The tokens themselves are unchanged — they're issued from the record the auth
server holds, so anything reading the email server-side (RLS policies, edge
functions) sees what the server stored, not the resolved address. Store it on
your own profile row if the backend needs it.

`Shovelbase.emailClaim(fromIdToken:)` exposes the claim read on its own, for
apps that want the address before exchanging the token.

### Signals behavior

- `track` is fire-and-forget — it never throws and never blocks the caller.
- Events are persisted to disk, so they survive app kills.
- Batches flush every 10 s, at 20 queued events, and when the app is
  backgrounded (tunable via the `signals:` parameter of `createClient`,
  or `ShovelbaseSignals.Options` standalone).
- Each event carries an `insert_id`, so a batch retried after a network
  timeout is never double-counted.
- Default properties sent with every event: `$os`, `$os_version`,
  `$app_version`, `$sdk`.
- Property values must be JSON-encodable; anything else is stringified.

Using signals without the client: add the `ShovelbaseSignals` product
instead and call `ShovelbaseSignals.configure(url:apiKey:)` at launch.
(`shovelbase.analytics` and the `ShovelbaseAnalytics` product remain as
deprecated aliases.)
