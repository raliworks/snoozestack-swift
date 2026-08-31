// The client's own wiring, and the wire contract of functions.invoke().
//
// This file used to prove that `.from()`/`.schema()`/`.rpc()` were compile
// errors on ShovelbaseClient — a guard that mattered while the type wrapped
// the upstream client and could re-inherit those names on a dependency bump
// (#151). 1.0 dropped the dependency (#209), so there is nothing left to
// inherit from and nothing to guard against; what is worth pinning now is
// that a function call still puts the same bytes on the wire that
// snoozestack-js does.
//
// No workflow builds sdk-swift on a PR (.github/workflows/sdk-swift.yml only
// publishes, on push to master) — `swift test` from sdk-swift/ is the bar.
import Foundation
import XCTest
@testable import Shovelbase

/// Captures the request a call makes and answers with a canned response,
/// without a network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data(#"{"ok":true}"#.utf8)

    static func reset() {
        lastRequest = nil
        lastBody = nil
        status = 200
        responseBody = Data(#"{"ok":true}"#.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLProtocol strips httpBody into a stream; read it back so the test
        // can assert on what was actually sent.
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct OKResponse: Decodable { let ok: Bool }

final class ShovelbaseClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        URLProtocol.registerClass(StubProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        super.tearDown()
    }

    private func makeClient() -> ShovelbaseClient {
        Shovelbase.createClient(
            url: "https://demo.shovelbase.com",
            key: "test-anon-key",
            // An in-memory store keeps the test off the real keychain.
            identity: .init(storage: MemoryIdentityStorage(), autoRefresh: false)
        )
    }

    func testCreateClientExposesTheNativeSurface() {
        let client = makeClient()
        XCTAssertEqual(client.url, "https://demo.shovelbase.com")
        XCTAssertEqual(client.identity.state, .anonymous)
        // Trailing slashes are trimmed so every service path appends cleanly.
        let trailing = Shovelbase.createClient(
            url: "https://demo.shovelbase.com/",
            key: "k",
            identity: .init(storage: MemoryIdentityStorage(), autoRefresh: false)
        )
        XCTAssertEqual(trailing.url, "https://demo.shovelbase.com")
    }

    func testInvokePostsToFunctionsV1WithTheApiKey() async throws {
        let client = makeClient()
        let _: OKResponse = try await client.functions.invoke("wallets")

        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://demo.shovelbase.com/functions/v1/wallets")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-anon-key")
        // No session yet, so the api key is the bearer — same default as
        // snoozestack-js.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-anon-key")
    }

    func testInvokeHonoursAnExplicitMethodAndEncodesAJSONBody() async throws {
        let client = makeClient()
        struct Charge: Encodable { let amount: Int }
        let _: OKResponse = try await client.functions.invoke(
            "charge", method: .patch, body: Charge(amount: 250)
        )

        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"amount":250}"#)
    }

    func testInvokeDoesNotOverrideACallerSuppliedAuthorization() async throws {
        let client = makeClient()
        let _: OKResponse = try await client.functions.invoke(
            "wallets", headers: ["Authorization": "Bearer explicit-token"]
        )
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer explicit-token")
    }

    func testInvokeSurfacesTheFunctionsOwnErrorMessage() async throws {
        StubProtocol.status = 402
        StubProtocol.responseBody = Data(#"{"error":"insufficient funds"}"#.utf8)
        let client = makeClient()

        do {
            let _: OKResponse = try await client.functions.invoke("charge")
            XCTFail("expected the call to throw")
        } catch let error as ShovelbaseFunctionsError {
            guard case let .http(status, message) = error else {
                return XCTFail("expected an http error, got \(error)")
            }
            XCTAssertEqual(status, 402)
            XCTAssertEqual(message, "insufficient funds")
        }
    }

    func testInvokeAppendsQueryItems() async throws {
        let client = makeClient()
        let _: OKResponse = try await client.functions.invoke(
            "wallets", method: .get, query: [URLQueryItem(name: "limit", value: "10")]
        )
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://demo.shovelbase.com/functions/v1/wallets?limit=10"
        )
    }
}

/// Session storage that never touches the keychain — tests only.
final class MemoryIdentityStorage: ShovelbaseIdentityStorage, @unchecked Sendable {
    private var values: [String: Data] = [:]
    func read(key: String) -> Data? { values[key] }
    func write(key: String, value: Data) { values[key] = value }
    func remove(key: String) { values[key] = nil }
}
