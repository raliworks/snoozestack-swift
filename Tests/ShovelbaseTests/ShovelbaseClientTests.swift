// Smoke tests for #151 (post-#123 parity with shovelbase-js's
// disableQueryBuilder()): ShovelbaseClient wraps the upstream SupabaseClient
// instead of aliasing it (see Shovelbase.swift's header comment for why),
// specifically so `.from()`/`.schema()`/`.rpc()` are not on its type surface
// — calling one is a compile error carrying a message that points at
// docs/migrations/postgrest-removal.md.
//
// No workflow builds sdk-swift on a PR (.github/workflows/sdk-swift.yml only
// publishes, on push to master, and has never run `swift build`/`swift test`
// — see its own header comment) — `swift test` from sdk-swift/ is the bar.
import Foundation
import Supabase
import XCTest
@testable import Shovelbase

/// A compile failure can't be asserted on from inside the same compilation
/// unit, so this shells out to `swiftc -typecheck` against a throwaway
/// fixture that calls all three removed methods, and checks both that it
/// fails *and* that the diagnostic is the actionable one this issue asked
/// for — not a generic "no such member" (which is what a caller would get if
/// the `@available(*, unavailable, message:)` overloads in Shovelbase.swift
/// were ever accidentally dropped instead of just renamed on an upstream
/// bump).
final class RemovedQueryBuilderCompileFailureTests: XCTestCase {
    func testFromSchemaRpcFailToCompileWithActionableMessage() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/ShovelbaseTests
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // package root (sdk-swift/)

        let (binPathStatus, binPathOutput) = try shell(
            "swift", ["build", "--show-bin-path"], currentDirectory: packageRoot
        )
        try XCTSkipUnless(
            binPathStatus == 0,
            "couldn't resolve the package's build directory: \(binPathOutput)"
        )
        let modulesPath = binPathOutput.trimmingCharacters(in: .whitespacesAndNewlines) + "/Modules"

        let fixture = """
        import Shovelbase
        func f(_ shovelbase: ShovelbaseClient) {
            _ = shovelbase.from("table")
            _ = shovelbase.schema("public")
            _ = shovelbase.rpc("fn")
        }
        """
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shovelbase-removed-query-builder-\(UUID().uuidString).swift")
        try fixture.write(to: fixtureURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let (status, output) = try shell("swiftc", ["-typecheck", fixtureURL.path, "-I", modulesPath])

        XCTAssertNotEqual(status, 0, "shovelbase.from/schema/rpc must fail to compile, but swiftc succeeded")
        // rpc's diagnostic names the overload ('rpc(_:count:)'), so match
        // loosely on the method name rather than an exact quoted identifier.
        for method in ["from", "schema", "rpc"] {
            XCTAssertTrue(
                output.contains("'\(method)") && output.contains("is unavailable"),
                "expected an 'unavailable' diagnostic for \(method); got:\n\(output)"
            )
        }
        XCTAssertTrue(
            output.contains("docs/migrations/postgrest-removal.md"),
            "diagnostic should point at the migration guide; got:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("shovelbase.functions.invoke"),
            "diagnostic should name the replacement pattern; got:\n\(output)"
        )
    }
}

/// The real regression risk in wrapping `SupabaseClient` instead of aliasing
/// it (as `ShovelbaseClient` did pre-#151) is a forwarding property wired up
/// wrong. No network calls here — constructing the client and reading each
/// forwarded property is enough to prove they resolve to the upstream
/// sub-clients instead of trapping.
final class ShovelbaseClientWrapperTests: XCTestCase {
    func testCreateClientForwardsUpstreamSurface() throws {
        let shovelbase = Shovelbase.createClient(
            url: "https://example.shovelbase.com",
            key: "test-anon-key"
        )

        _ = shovelbase.auth
        _ = shovelbase.storage
        _ = shovelbase.functions
        _ = shovelbase.realtimeV2
        _ = shovelbase.channels
        _ = shovelbase.headers
        _ = shovelbase.signals
        _ = shovelbase.push
        // .base is the escape hatch to the wrapped upstream client (see
        // Shovelbase.swift) — prove createClient() actually populated it.
        XCTAssertEqual(shovelbase.base.headers["Apikey"], "test-anon-key")
    }
}

private func shell(
    _ command: String,
    _ arguments: [String],
    currentDirectory: URL? = nil
) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments
    if let currentDirectory {
        process.currentDirectoryURL = currentDirectory
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
