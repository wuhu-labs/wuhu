import Foundation
import PiAI
import WuhuAPI

public struct WuhuClient: Sendable {
  public var baseURL: URL
  private let http: any HTTPClient

  public init(baseURL: URL, http: any HTTPClient = AsyncHTTPClientTransport()) {
    self.baseURL = baseURL
    self.http = http
  }

  public func createSession(_ request: WuhuCreateSessionRequest) async throws -> WuhuSession {
    let url = baseURL.appending(path: "v1").appending(path: "sessions")
    var req = HTTPRequest(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.body = try WuhuJSON.encoder.encode(request)

    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuSession.self, from: data)
  }

  public func listSessions(limit: Int? = nil) async throws -> [WuhuSession] {
    var url = baseURL.appending(path: "v1").appending(path: "sessions")
    if let limit {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
      url = components?.url ?? url
    }

    let req = HTTPRequest(url: url, method: "GET")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode([WuhuSession].self, from: data)
  }

  public func getSession(id: String) async throws -> WuhuGetSessionResponse {
    let url = baseURL.appending(path: "v1").appending(path: "sessions").appending(path: id)
    let req = HTTPRequest(url: url, method: "GET")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuGetSessionResponse.self, from: data)
  }

  public func promptStream(
    sessionID: String,
    input: String,
    maxTurns: Int? = nil,
  ) async throws -> AsyncThrowingStream<WuhuPromptEvent, any Error> {
    let url = baseURL.appending(path: "v1").appending(path: "sessions").appending(path: sessionID).appending(path: "prompt")
    var req = HTTPRequest(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("text/event-stream", for: "Accept")
    req.body = try WuhuJSON.encoder.encode(WuhuPromptRequest(input: input, maxTurns: maxTurns))

    let sse = try await http.sse(for: req)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await message in sse {
            guard let data = message.data.data(using: .utf8) else { continue }
            let event = try WuhuJSON.decoder.decode(WuhuPromptEvent.self, from: data)
            continuation.yield(event)
            if case .done = event { break }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
