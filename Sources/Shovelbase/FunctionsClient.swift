// Calling a project's functions, over URLSession.
//
// This replaces the upstream edge-runtime client the package used to wrap
// (#209). The wire contract is unchanged — POST (or an explicit method) to
// `<base>/functions/v1/<name>`, `apikey` plus a bearer token, a JSON body —
// so a function called from Swift and the same one called from
// shovelbase-js see identical requests.
//
// A call automatically carries the signed-in application user's session
// (`Authorization: Bearer <session_token>`, the transport convention #100's
// function-side verification expects) without every call site threading it
// through by hand. An explicitly-passed Authorization always wins.
//
// Unlike the JS client this throws rather than returning a result pair:
// `try await` is how Swift call sites already read, and there is no existing
// caller expecting `{ data, error }` to preserve.
import Foundation

/// A failed function call.
public enum ShovelbaseFunctionsError: Error, LocalizedError {
  /// The function answered with a non-2xx status.
  case http(status: Int, message: String)
  /// The request never got an answer.
  case transport(underlying: Error)
  /// The answer arrived but could not be decoded as the requested type.
  case decoding(underlying: Error)

  public var errorDescription: String? {
    switch self {
    case let .http(status, message):
      return message.isEmpty ? "The function failed with status \(status)." : message
    case let .transport(underlying):
      return "The function could not be reached: \(underlying.localizedDescription)"
    case let .decoding(underlying):
      return "The function's response could not be decoded: \(underlying.localizedDescription)"
    }
  }
}

public final class ShovelbaseFunctionsClient: Sendable {
  /// HTTP method for a function call. POST unless stated otherwise — a
  /// function call is a command by default; a reading function is a GET.
  public enum Method: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
  }

  private let url: String
  private let key: String
  private let identity: ShovelbaseIdentity

  init(url: String, key: String, identity: ShovelbaseIdentity) {
    self.url = url
    self.key = key
    self.identity = identity
  }

  private func request(
    _ functionName: String,
    method: Method?,
    query: [URLQueryItem],
    headers: [String: String],
    body: Data?,
    hasJSONBody: Bool
  ) async throws -> Data {
    guard var components = URLComponents(string: "\(url)/functions/v1/\(functionName)") else {
      throw ShovelbaseFunctionsError.http(status: 0, message: "Invalid function URL for \(functionName).")
    }
    if !query.isEmpty { components.queryItems = query }
    guard let requestURL = components.url else {
      throw ShovelbaseFunctionsError.http(status: 0, message: "Invalid function URL for \(functionName).")
    }

    var request = URLRequest(url: requestURL)
    request.httpMethod = (method ?? .post).rawValue
    request.httpBody = body
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if request.value(forHTTPHeaderField: "apikey") == nil {
      request.setValue(key, forHTTPHeaderField: "apikey")
    }
    // A caller-supplied Authorization always wins: passing one explicitly is
    // how a call acts as something other than the signed-in user.
    if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
      // Refresh before sending, not on a timer: a backgrounded or sleeping
      // app stops timers, so the session in memory when the person comes back
      // may already have expired.
      try? await identity.ensureFreshSession()
      let token = identity.session?.sessionToken ?? key
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if hasJSONBody, request.value(forHTTPHeaderField: "Content-Type") == nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw ShovelbaseFunctionsError.transport(underlying: error)
    }

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      // Functions conventionally answer { "error": "..." }; that text is far
      // more useful than the status alone.
      var message = ""
      if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let detail = object["error"] as? String {
        message = detail
      } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
        message = text
      }
      throw ShovelbaseFunctionsError.http(status: status, message: message)
    }
    return data
  }

  /// Invokes a function with a body, decoding the response as `T`.
  @discardableResult
  public func invoke<T: Decodable>(
    _ functionName: String,
    method: Method? = nil,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: some Encodable,
    encoder: JSONEncoder = JSONEncoder(),
    decoder: JSONDecoder = JSONDecoder()
  ) async throws -> T {
    let encoded = try encoder.encode(body)
    let data = try await request(
      functionName, method: method, query: query, headers: headers, body: encoded, hasJSONBody: true
    )
    do {
      return try decoder.decode(T.self, from: data)
    } catch {
      throw ShovelbaseFunctionsError.decoding(underlying: error)
    }
  }

  /// Invokes a function with no body, decoding the response as `T`.
  @discardableResult
  public func invoke<T: Decodable>(
    _ functionName: String,
    method: Method? = nil,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    decoder: JSONDecoder = JSONDecoder()
  ) async throws -> T {
    let data = try await request(
      functionName, method: method, query: query, headers: headers, body: nil, hasJSONBody: false
    )
    do {
      return try decoder.decode(T.self, from: data)
    } catch {
      throw ShovelbaseFunctionsError.decoding(underlying: error)
    }
  }

  /// Invokes a function with a body, ignoring the response body.
  public func invoke(
    _ functionName: String,
    method: Method? = nil,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: some Encodable,
    encoder: JSONEncoder = JSONEncoder()
  ) async throws {
    let encoded = try encoder.encode(body)
    _ = try await request(
      functionName, method: method, query: query, headers: headers, body: encoded, hasJSONBody: true
    )
  }

  /// Invokes a function with no body, ignoring the response body.
  public func invoke(
    _ functionName: String,
    method: Method? = nil,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:]
  ) async throws {
    _ = try await request(
      functionName, method: method, query: query, headers: headers, body: nil, hasJSONBody: false
    )
  }

  /// Invokes a function, returning the raw response bytes.
  public func invokeRaw(
    _ functionName: String,
    method: Method? = nil,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: Data? = nil
  ) async throws -> Data {
    try await request(
      functionName, method: method, query: query, headers: headers, body: body, hasJSONBody: body != nil
    )
  }
}
