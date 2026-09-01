// Backwards-compatibility module for the Analytics → Signals rename.
//
// The implementation moved to the `SnoozestackSignals` target; this target only
// re-exports it (and the `SnoozestackAnalytics` typealias defined there) so that
// existing `import SnoozestackAnalytics` call sites keep compiling. New code
// should `import SnoozestackSignals`.
@_exported import SnoozestackSignals
