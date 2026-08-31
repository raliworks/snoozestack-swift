// The snoozestack-named face of the SDK (the shovelbase → snoozestack rename).
//
// The implementation stays in the `Shovelbase` target so existing
// `import Shovelbase` call sites keep compiling; this target re-exports it.
// New code should `import Snoozestack`.
@_exported import Shovelbase
