// Wraps the upstream FunctionsClient so shovelbase.functions.invoke(...)
// automatically carries the signed-in application user's session (#101) —
// `Authorization: Bearer <session_token>`, the transport convention #100's
// function-side verification expects — without every call site having to
// thread it through by hand.
//
// FunctionsClient itself is `final` (can't subclass) and its
// FunctionInvokeOptions.headers is not readable once constructed (no public
// getter upstream), so interception happens one level up: this wrapper takes
// the same parameters FunctionInvokeOptions' own public initializers do,
// merges in the current session's bearer token itself, then builds the
// options and delegates to the wrapped client. Mirrors
// disableQueryBuilder()/ShovelbaseClient's own wrapper-not-alias pattern
// (see Shovelbase.swift's header comment) for the same reason: changing
// behavior on a type Swift won't let us subclass.
import Foundation
import Supabase

public final class ShovelbaseFunctionsClient: Sendable {
  /// The wrapped upstream client — an escape hatch for the one upstream
  /// overload not mirrored here (the raw `decode:` closure variant); calls
  /// through `.base` do not get the session auto-attached.
  public let base: FunctionsClient
  private let identity: ShovelbaseIdentity

  init(base: FunctionsClient, identity: ShovelbaseIdentity) {
    self.base = base
    self.identity = identity
  }

  private func headers(mergingSessionInto headers: [String: String]) -> [String: String] {
    guard let token = identity.session?.sessionToken else { return headers }
    guard !headers.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) else { return headers }
    var merged = headers
    merged["Authorization"] = "Bearer \(token)"
    return merged
  }

  /// Invokes a function with a body, decoding the response as `T`.
  public func invoke<T: Decodable>(
    _ functionName: String,
    method: FunctionInvokeOptions.Method? = nil,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    region: String? = nil,
    body: some Encodable,
    decoder: JSONDecoder = JSONDecoder()
  ) async throws -> T {
    let merged = self.headers(mergingSessionInto: headers)
    return try await base.invoke(
      functionName,
      options: FunctionInvokeOptions(method: method, query: query, headers: merged, region: region, body: body),
      decoder: decoder
    )
  }

  /// Invokes a function with no body, decoding the response as `T`.
  public func invoke<T: Decodable>(
    _ functionName: String,
    method: FunctionInvokeOptions.Method? = nil,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    region: String? = nil,
    decoder: JSONDecoder = JSONDecoder()
  ) async throws -> T {
    let merged = self.headers(mergingSessionInto: headers)
    return try await base.invoke(
      functionName,
      options: FunctionInvokeOptions(method: method, query: query, headers: merged, region: region),
      decoder: decoder
    )
  }

  /// Invokes a function with a body, ignoring the response body.
  public func invoke(
    _ functionName: String,
    method: FunctionInvokeOptions.Method? = nil,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    region: String? = nil,
    body: some Encodable
  ) async throws {
    let merged = self.headers(mergingSessionInto: headers)
    try await base.invoke(
      functionName,
      options: FunctionInvokeOptions(method: method, query: query, headers: merged, region: region, body: body)
    )
  }

  /// Invokes a function with no body, ignoring the response body.
  public func invoke(
    _ functionName: String,
    method: FunctionInvokeOptions.Method? = nil,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    region: String? = nil
  ) async throws {
    let merged = self.headers(mergingSessionInto: headers)
    try await base.invoke(
      functionName,
      options: FunctionInvokeOptions(method: method, query: query, headers: merged, region: region)
    )
  }
}
