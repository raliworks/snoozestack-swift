# snoozestack-swift

> Part of the [codebase guide](../CODEBASE.md). Neighbors: [sdk](../sdk/README.md) · [portal-ios](../portal-ios/README.md)

Swift client for [snoozestack](../README.md) projects on iOS, macOS, tvOS, and
watchOS — application identity, functions, signals and push.

As of 1.0 the package has no third-party dependencies (#209). It used to wrap
the upstream supabase client, which is why three surfaces you may remember
are gone:

| Removed | Replacement |
|---|---|
| `.auth` | `.identity` — application identity, below |
| `.storage` | a function that returns a signed URL; PUT to it directly. For a public bucket, build the object URL: `<SNOOZESTACK_URL>/storage/v1/object/public/<bucket>/<path>` |
| `.from()` / `.schema()` / `.rpc()` | removed with PostgREST (`../docs/migrations/postgrest-removal.md`) — read or write the database from a committed function, over its own `SNOOZESTACK_DB_URL` |

`.base` (the wrapped upstream client) is gone with them. SPM consumers pin
versions, so nothing already shipped changes under you.

Library products:

- **`SnoozeStack`** — the full client (`SnoozeStack.createClient`, `.identity`,
  `.functions`, `.signals`, `.push`).
- **`SnoozeStackSignals`** — event tracking only; a single file, if you don't
  need the rest. (`SnoozeStackAnalytics` remains as a deprecated alias product.)
- **`SnoozeStackPush`** — push notification registration only.

## Install

The package lives at [github.com/raliworks/snoozestack-swift](https://github.com/raliworks/snoozestack-swift).
In Xcode: **File → Add Package Dependencies…**, paste

```
https://github.com/raliworks/snoozestack-swift.git
```

choose **Up to Next Major Version**, and add the `SnoozeStack` library to
your app target. Or in a `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/raliworks/snoozestack-swift.git",
        from: "1.0.0"
    ),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SnoozeStack", package: "snoozestack-swift"),
    ]),
]
```

The same history is also served from
`https://snoozestack.com/swift/snoozestack-swift.git` (git's dumb-HTTP
protocol, which SwiftPM on the command line can fetch but Xcode's Add Package
sheet cannot) — projects that already depend on that URL keep working.

To release a new version: push to master (`scripts/publish-sdks.sh swift`
commits the current `sdk-swift/` content to the hosted repo, tags it, and
pushes the tag to GitHub — published versions are immutable), then update the
dependency in Xcode (*File → Packages → Update to Latest Package Versions*).

## Use

```swift
import SnoozeStack

// Once, at launch (e.g. in your App init).
// URL + anon key: portal → Project Settings → API.
let snoozestack = SnoozeStack.createClient(
    url: "https://<project-ref>.snoozestack.com",   // SNOOZESTACK_URL
    key: "<SNOOZESTACK_ANON_KEY>"
)

// Application identity
let user = try await snoozestack.identity.signInWithPassword(email: email, password: password)

// Functions — POST by default, and the signed-in session is attached for you
let reply: ChatReply = try await snoozestack.functions
    .invoke("kyd-golf-chat", body: ["messages": messages])

// Signals (event tracking; charted on the portal's Signals page)
snoozestack.signals.identify(user.id)  // merges their anonymous history in
snoozestack.signals.track("signup", properties: ["plan": "pro"])
snoozestack.signals.reset()                        // on sign-out
```

Supporting types come from the same `import SnoozeStack`. Not supported:
realtime subscriptions.

### Application identity (magic link, password, OAuth, sessions)

`.identity` is sign-in for your own hosted application's users — this
project's own end-user population, not snoozestack operators. See
`../docs/app-identity-client-contract.md` for the full state machine and
error taxonomy (shared with the JS SDK).

```swift
try await snoozestack.identity.requestMagicLink(
    email: email, redirectTo: "https://myapp.example.com/callback"
)
// ... user clicks the emailed link; your app opens on
//     https://myapp.example.com/callback?token=... ...
let result = try await snoozestack.identity.completeMagicLink(token: token)
result.user.email

// snoozestack.functions.invoke(...) automatically carries
// `.identity`'s session once one exists — no extra wiring needed.
let reply: ChatReply = try await snoozestack.functions.invoke("kyd-golf-chat", body: ["messages": messages])

await snoozestack.identity.signOut()
```

OAuth: `startOAuth(provider:redirectTo:)` returns the authorize URL to open
(`ASWebAuthenticationSession` or `UIApplication.open(_:)`); your app's
universal-link handler passes the resulting `redirectTo` URL to
`completeOAuthCallback(url:)`.

`snoozestack.identity.onStateChange { state, session, user in ... }` observes
`.anonymous` / `.pending` / `.authenticated` / `.expired` reactively.

### Sign in with Apple

Native apps sign in by ID token — pass the credential from
`ASAuthorizationController` straight through, and the user never leaves the
app:

```swift
let result = try await snoozestack.identity.signInWithIdToken(
    provider: "apple", idToken: idToken, nonce: nonce
)
result.user.email
result.isNewUser   // a native sign-in has no separate sign-up
```

Hide My Email is handled server-side: Apple puts the relay address in the
identity token's `email` claim on every sign-in, and the auth server reads it
from there when creating or updating the record — so `result.user.email` is
the `…@privaterelay.appleid.com` address rather than nil, on the first
sign-in and every one after.

(Before 1.0 this needed a client-side workaround,
`signInWithIdTokenResolvingPrivateRelay`, because the upstream auth client
only saw what the credential object carried — which Apple drops after the
first authorization. That surface is gone with `.auth`.)

The project must have the provider's native client id registered, or the
call is rejected — see `../docs/app-identity-client-contract.md`.

### Signals behavior

- `track` is fire-and-forget — it never throws and never blocks the caller.
- Events are persisted to disk, so they survive app kills.
- Batches flush every 10 s, at 20 queued events, and when the app is
  backgrounded (tunable via the `signals:` parameter of `createClient`,
  or `SnoozeStackSignals.Options` standalone).
- Each event carries an `insert_id`, so a batch retried after a network
  timeout is never double-counted.
- Default properties sent with every event: `$os`, `$os_version`,
  `$app_version`, `$sdk`.
- Property values must be JSON-encodable; anything else is stringified.

Using signals without the client: add the `SnoozeStackSignals` product
instead and call `SnoozeStackSignals.configure(url:apiKey:)` at launch.
(`snoozestack.analytics` and the `SnoozeStackAnalytics` product remain as
deprecated aliases.)
