// The snoozestack-named face of the SDK (the snoozestack → snoozestack rename).
//
// The implementation stays in the `Snoozestack` target so existing
// `import Snoozestack` call sites keep compiling; this target re-exports it.
// New code should `import Snoozestack`.
@_exported import Shovelbase

// Type-level aliases so new code can use snoozestack-named types; the
// Shovelbase* originals stay for every app written before the rename.
public typealias SnoozestackClient = ShovelbaseClient
public typealias SnoozestackIdentity = ShovelbaseIdentity
public typealias SnoozestackIdentityError = ShovelbaseIdentityError
public typealias SnoozestackFunctionsClient = ShovelbaseFunctionsClient
public typealias SnoozestackFunctionsError = ShovelbaseFunctionsError
public typealias SnoozestackKit = Shovelbase
