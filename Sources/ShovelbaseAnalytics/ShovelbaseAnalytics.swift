// Backwards-compatibility module for the Analytics → Signals rename.
//
// The implementation moved to the `ShovelbaseSignals` target; this target only
// re-exports it (and the `ShovelbaseAnalytics` typealias defined there) so that
// existing `import ShovelbaseAnalytics` call sites keep compiling. New code
// should `import ShovelbaseSignals`.
@_exported import ShovelbaseSignals
