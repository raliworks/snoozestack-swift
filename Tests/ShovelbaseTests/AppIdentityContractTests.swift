// Tests for ShovelbaseIdentity (#101) against the shared identity-client
// contract fixture (../../../sdk/test/app-identity-contract.json — see
// ../../../docs/app-identity-client-contract.md for the prose version).
// sdk/src/app-identity.test.mjs asserts against the same fixture on the JS
// side, so a shape change in one SDK's tests is forced to also break the
// other's.
import Foundation
import XCTest
@testable import Shovelbase

private let BASE = "https://demo.shovelbase.com"
private let KEY = "test-anon-key"

// MARK: - Contract fixture

private enum Contract {
  static let root: [String: Any] = {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // .../Tests/ShovelbaseTests
      .deletingLastPathComponent()  // .../Tests
      .deletingLastPathComponent()  // package root (sdk-swift/)
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("sdk/test/app-identity-contract.json")
    guard let data = try? Data(contentsOf: fixtureURL),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      fatalError("couldn't load the shared identity contract fixture at \(fixtureURL.path)")
    }
    return json
  }()

  static var errorCodes: [String] { root["errorCodes"] as! [String] }
  static var routes: [String: Any] { root["routes"] as! [String: Any] }
  static func route(_ name: String) -> [String: Any] { routes[name] as! [String: Any] }
}

// MARK: - Mock transport

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
  nonisolated(unsafe) static var requestCount = 0

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.requestCount += 1
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let (status, data) = handler(request)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class InMemoryIdentityStorage: ShovelbaseIdentityStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var store: [String: Data] = [:]

  func read(key: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return store[key]
  }
  func write(key: String, value: Data) {
    lock.lock()
    defer { lock.unlock() }
    store[key] = value
  }
  func remove(key: String) {
    lock.lock()
    defer { lock.unlock() }
    store.removeValue(forKey: key)
  }
}

private func mockSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: config)
}

private func jsonData(_ object: Any) -> Data {
  try! JSONSerialization.data(withJSONObject: object)
}

private func makeIdentity(namespace: String = "default", storage: any ShovelbaseIdentityStorage = InMemoryIdentityStorage()) -> ShovelbaseIdentity {
  ShovelbaseIdentity(
    url: BASE, apiKey: KEY,
    options: .init(namespace: namespace, storage: storage, autoRefresh: false),
    urlSession: mockSession()
  )
}

// MARK: - Tests

final class AppIdentityContractTests: XCTestCase {

  func testContractFixtureHasEveryTaxonomyCode() {
    let codes = Set(Contract.errorCodes)
    let enumCodes: Set<String> = [
      "invalid_redirect", "rate_limited", "invalid_or_expired_link", "invalid_or_expired_session",
      "oauth_denied", "missing_code", "oauth_failed", "network_error", "not_configured", "server_error",
    ]
    XCTAssertEqual(codes, enumCodes)
  }

  func testStartsAnonymousWithNoStoredSession() {
    let identity = makeIdentity()
    XCTAssertEqual(identity.state, .anonymous)
    XCTAssertNil(identity.session)
    XCTAssertNil(identity.user)
  }

  func testRequestMagicLinkPostsContractShapeAndMovesToPending() async throws {
    let fixture = Contract.route("magicLinkRequest")
    let success = fixture["success"] as! [String: Any]
    var seenPath: String?
    MockURLProtocol.handler = { request in
      seenPath = request.url?.path
      return (success["status"] as! Int, jsonData(success["body"] as! [String: Any]))
    }
    let identity = makeIdentity()
    try await identity.requestMagicLink(email: "person@example.com", redirectTo: "https://app.example.com/callback")
    XCTAssertEqual(seenPath, fixture["path"] as? String)
    XCTAssertEqual(identity.state, .pending)
  }

  func testRequestMagicLinkMapsEveryDocumentedErrorCode() async throws {
    let fixture = Contract.route("magicLinkRequest")
    let errors = fixture["errors"] as! [[String: Any]]
    for errorCase in errors {
      let status = errorCase["status"] as! Int
      let body = errorCase["body"] as! [String: Any]
      let expectedCode = errorCase["code"] as! String
      MockURLProtocol.handler = { _ in (status, jsonData(body)) }
      let identity = makeIdentity()
      do {
        try await identity.requestMagicLink(email: "x@example.com", redirectTo: "https://app.example.com/callback")
        XCTFail("expected \(expectedCode) to be thrown")
      } catch let error as ShovelbaseIdentityError {
        XCTAssertEqual(error.code.rawValue, expectedCode)
        XCTAssertEqual(error.status, status)
      }
    }
  }

  func testCompleteMagicLinkAppliesSessionAndMovesToAuthenticated() async throws {
    let fixture = Contract.route("magicLinkVerify")
    let success = fixture["success"] as! [String: Any]
    let body = success["body"] as! [String: Any]
    MockURLProtocol.handler = { _ in (success["status"] as! Int, jsonData(body)) }
    let identity = makeIdentity()
    let result = try await identity.completeMagicLink(token: "deadbeef")
    XCTAssertEqual(identity.state, .authenticated)
    XCTAssertEqual(identity.session?.sessionToken, body["session_token"] as? String)
    XCTAssertEqual(identity.user?.email, (body["user"] as! [String: Any])["email"] as? String)
    XCTAssertTrue(result.isNewUser)
  }

  func testCompleteMagicLinkOn404ThrowsAndStaysAnonymous() async throws {
    let fixture = Contract.route("magicLinkVerify")
    let errors = fixture["errors"] as! [[String: Any]]
    let notFound = errors.first { ($0["status"] as! Int) == 404 }!
    MockURLProtocol.handler = { _ in (404, jsonData(notFound["body"] as! [String: Any])) }
    let identity = makeIdentity()
    do {
      _ = try await identity.completeMagicLink(token: "used-already")
      XCTFail("expected an error")
    } catch let error as ShovelbaseIdentityError {
      XCTAssertEqual(error.code, .invalidOrExpiredLink)
    }
    XCTAssertEqual(identity.state, .anonymous)
  }

  func testCompleteMagicLinkDeDupesConcurrentCallsForSameToken() async throws {
    let fixture = Contract.route("magicLinkVerify")
    let body = (fixture["success"] as! [String: Any])["body"] as! [String: Any]
    MockURLProtocol.requestCount = 0
    MockURLProtocol.handler = { _ in (200, jsonData(body)) }
    let identity = makeIdentity()
    async let a = identity.completeMagicLink(token: "same-token")
    async let b = identity.completeMagicLink(token: "same-token")
    let (resultA, resultB) = try await (a, b)
    XCTAssertEqual(MockURLProtocol.requestCount, 1, "a token already being redeemed must not be POSTed twice")
    XCTAssertEqual(resultA.user, resultB.user)
  }

  func testStartOAuthBuildsDocumentedURLAndMovesToPending() {
    let identity = makeIdentity(namespace: "preview:pr-42")
    let url = identity.startOAuth(provider: "google", redirectTo: "https://app.example.com/callback")
    XCTAssertEqual(url.path, "/auth/oauth/google/start")
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value) })
    XCTAssertEqual(query["apikey"] ?? nil, KEY)
    XCTAssertEqual(query["redirect_to"] ?? nil, "https://app.example.com/callback")
    XCTAssertEqual(query["namespace"] ?? nil, "preview:pr-42")
    XCTAssertEqual(identity.state, .pending)
  }

  func testCompleteOAuthCallbackReadsFragmentAndMovesToAuthenticated() async throws {
    let fixture = Contract.route("oauthCallback")
    let fragmentDict = ((fixture["success"] as! [String: Any])["redirectFragment"] as! [String: String])
    let fragment = fragmentDict.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    let identity = makeIdentity()
    let result = try await identity.completeOAuthCallback(url: URL(string: "https://app.example.com/callback#\(fragment)")!)
    XCTAssertEqual(identity.state, .authenticated)
    XCTAssertEqual(identity.session?.sessionToken, fragmentDict["session_token"])
    XCTAssertEqual(identity.user?.id, fragmentDict["user_id"])
    XCTAssertTrue(result.isNewUser)
  }

  func testCompleteOAuthCallbackMapsEveryDocumentedFragmentErrorCode() async throws {
    let fixture = Contract.route("oauthCallback")
    let errors = fixture["errors"] as! [[String: Any]]
    for errorCase in errors {
      guard let fragmentDict = errorCase["redirectFragment"] as? [String: String] else { continue }
      let expectedCode = errorCase["code"] as! String
      let fragment = fragmentDict.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
      let identity = makeIdentity()
      do {
        _ = try await identity.completeOAuthCallback(url: URL(string: "https://app.example.com/callback#\(fragment)")!)
        XCTFail("expected \(expectedCode) to be thrown")
      } catch let error as ShovelbaseIdentityError {
        XCTAssertEqual(error.code.rawValue, expectedCode)
      }
      XCTAssertEqual(identity.state, .anonymous)
    }
  }

  func testRefreshRotatesBothTokensAndStaysAuthenticated() async throws {
    let verifyBody = ((Contract.route("magicLinkVerify"))["success"] as! [String: Any])["body"] as! [String: Any]
    let refreshFixture = Contract.route("sessionRefresh")
    let refreshBody = (refreshFixture["success"] as! [String: Any])["body"] as! [String: Any]
    var call = 0
    MockURLProtocol.handler = { request in
      call += 1
      if call == 1 { return (200, jsonData(verifyBody)) }
      XCTAssertEqual(request.url?.path, refreshFixture["path"] as? String)
      return (200, jsonData(refreshBody))
    }
    let identity = makeIdentity()
    _ = try await identity.completeMagicLink(token: "tok")
    let session = try await identity.refresh()
    XCTAssertEqual(session.sessionToken, refreshBody["session_token"] as? String)
    XCTAssertNotEqual(session.sessionToken, verifyBody["session_token"] as? String)
    XCTAssertEqual(identity.state, .authenticated)
  }

  func testRefreshOnRevokedTokenMovesToExpiredAndClearsStorage() async throws {
    let verifyBody = ((Contract.route("magicLinkVerify"))["success"] as! [String: Any])["body"] as! [String: Any]
    let refreshFixture = Contract.route("sessionRefresh")
    let errorCase = (refreshFixture["errors"] as! [[String: Any]])[0]
    var call = 0
    MockURLProtocol.handler = { _ in
      call += 1
      if call == 1 { return (200, jsonData(verifyBody)) }
      return (errorCase["status"] as! Int, jsonData(errorCase["body"] as! [String: Any]))
    }
    let identity = makeIdentity()
    _ = try await identity.completeMagicLink(token: "tok")
    do {
      _ = try await identity.refresh()
      XCTFail("expected an error")
    } catch let error as ShovelbaseIdentityError {
      XCTAssertEqual(error.code, .invalidOrExpiredSession)
    }
    XCTAssertEqual(identity.state, .expired)
    XCTAssertNil(identity.session)
  }

  func testSignOutClearsLocalStateEvenWhenServerCallFails() async throws {
    let verifyBody = ((Contract.route("magicLinkVerify"))["success"] as! [String: Any])["body"] as! [String: Any]
    var call = 0
    MockURLProtocol.handler = { _ in
      call += 1
      if call == 1 { return (200, jsonData(verifyBody)) }
      return (500, jsonData(["error": "boom"]))
    }
    let identity = makeIdentity()
    _ = try await identity.completeMagicLink(token: "tok")
    XCTAssertEqual(identity.state, .authenticated)
    await identity.signOut()
    XCTAssertEqual(identity.state, .anonymous)
    XCTAssertNil(identity.session)
    XCTAssertNil(identity.user)
  }

  func testOnStateChangeFiresImmediatelyAndOnEveryTransition() async throws {
    let verifyBody = ((Contract.route("magicLinkVerify"))["success"] as! [String: Any])["body"] as! [String: Any]
    MockURLProtocol.handler = { _ in (200, jsonData(verifyBody)) }
    let identity = makeIdentity()
    let seen = SeenStates()
    let unsubscribe = identity.onStateChange { state, _, _ in seen.append(state) }
    XCTAssertEqual(seen.values, [.anonymous])
    _ = try await identity.completeMagicLink(token: "tok")
    XCTAssertEqual(seen.values, [.anonymous, .pending, .authenticated])
    unsubscribe()
    await identity.signOut()
    XCTAssertEqual(seen.values, [.anonymous, .pending, .authenticated], "no further calls after unsubscribe")
  }

  func testSessionsAreNamespacedSoTwoNamespacesNeverCollideInSharedStorage() async throws {
    let verifyBody = ((Contract.route("magicLinkVerify"))["success"] as! [String: Any])["body"] as! [String: Any]
    MockURLProtocol.handler = { _ in (200, jsonData(verifyBody)) }
    let sharedStorage = InMemoryIdentityStorage()

    let dev = makeIdentity(namespace: "dev", storage: sharedStorage)
    _ = try await dev.completeMagicLink(token: "tok")
    XCTAssertEqual(dev.state, .authenticated)

    let live = makeIdentity(namespace: "default", storage: sharedStorage)
    XCTAssertEqual(live.state, .anonymous, "a fresh instance in a different namespace must not pick up dev's session")
  }
}

/// Thread-safe accumulator for onStateChange's listener callback (which is
/// `@Sendable` and may fire off the calling thread) — `setState` invokes
/// listeners synchronously, so a plain lock (not an actor) keeps assertions
/// in these tests synchronous too, with no hop needed to observe a value.
final class SeenStates: @unchecked Sendable {
  private let lock = NSLock()
  private var _values: [IdentityState] = []
  var values: [IdentityState] {
    lock.lock()
    defer { lock.unlock() }
    return _values
  }
  func append(_ state: IdentityState) {
    lock.lock()
    defer { lock.unlock() }
    _values.append(state)
  }
}
