import Foundation
import PiAI
import WuhuAPI
import WuhuCoreClient

public struct WuhuClient: Sendable {
  public var baseURL: URL
  private let http: any HTTPClient

  public enum EnqueueLane: String, Sendable, Hashable {
    case steer
    case followUp
  }

  public init(baseURL: URL, http: any HTTPClient = AsyncHTTPClientTransport()) {
    self.baseURL = baseURL
    self.http = http
  }

  public func listRunners() async throws -> [WuhuRunnerInfo] {
    let url = baseURL.appending(path: "v1").appending(path: "runners")
    let req = HTTPRequest(url: url, method: "GET")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode([WuhuRunnerInfo].self, from: data)
  }

  public func listEnvironments() async throws -> [WuhuEnvironmentDefinition] {
    let url = baseURL.appending(path: "v1").appending(path: "environments")
    let req = HTTPRequest(url: url, method: "GET")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode([WuhuEnvironmentDefinition].self, from: data)
  }

  public func createEnvironment(_ request: WuhuCreateEnvironmentRequest) async throws -> WuhuEnvironmentDefinition {
    let url = baseURL.appending(path: "v1").appending(path: "environments")
    var req = HTTPRequest(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.body = try WuhuJSON.encoder.encode(request)
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuEnvironmentDefinition.self, from: data)
  }

  public func getEnvironment(_ identifier: String) async throws -> WuhuEnvironmentDefinition {
    let url = baseURL.appending(path: "v1").appending(path: "environments").appending(path: identifier)
    let req = HTTPRequest(url: url, method: "GET")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuEnvironmentDefinition.self, from: data)
  }

  public func updateEnvironment(_ identifier: String, request: WuhuUpdateEnvironmentRequest) async throws -> WuhuEnvironmentDefinition {
    let url = baseURL.appending(path: "v1").appending(path: "environments").appending(path: identifier)
    var req = HTTPRequest(url: url, method: "PATCH")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.body = try WuhuJSON.encoder.encode(request)
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuEnvironmentDefinition.self, from: data)
  }

  public func deleteEnvironment(_ identifier: String) async throws {
    let url = baseURL.appending(path: "v1").appending(path: "environments").appending(path: identifier)
    let req = HTTPRequest(url: url, method: "DELETE")
    _ = try await http.data(for: req)
  }

  public func listWorkspaceDocs() async throws -> [WuhuWorkspaceDocSummary] {
    let url = baseURL.appending(path: "v1").appending(path: "workspace").appending(path: "docs")
    let req = HTTPRequest(url: url, method: "GET")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode([WuhuWorkspaceDocSummary].self, from: data)
  }

  public func readWorkspaceDoc(path: String) async throws -> WuhuWorkspaceDoc {
    var url = baseURL.appending(path: "v1").appending(path: "workspace").appending(path: "doc")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "path", value: path)]
    url = components?.url ?? url

    let req = HTTPRequest(url: url, method: "GET")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuWorkspaceDoc.self, from: data)
  }

  public func createSession(_ request: WuhuCreateSessionRequest) async throws -> WuhuSession {
    let url = baseURL.appending(path: "v1").appending(path: "sessions")
    var req = HTTPRequest(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.body = try WuhuJSON.encoder.encode(request)

    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuSession.self, from: data)
  }

  public func renameSession(id: String, title: String) async throws -> WuhuRenameSessionResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: id)
    var req = HTTPRequest(url: url, method: "PATCH")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.body = try WuhuJSON.encoder.encode(WuhuRenameSessionRequest(title: title))

    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuRenameSessionResponse.self, from: data)
  }

  public func setSessionModel(
    sessionID: String,
    provider: WuhuProvider,
    model: String? = nil,
    reasoningEffort: ReasoningEffort? = nil,
  ) async throws -> WuhuSetSessionModelResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "model")
    var req = HTTPRequest(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.body = try WuhuJSON.encoder.encode(WuhuSetSessionModelRequest(
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
    ))

    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuSetSessionModelResponse.self, from: data)
  }

  public func listSessions(limit: Int? = nil, includeArchived: Bool = false) async throws -> [WuhuSession] {
    var url = baseURL.appending(path: "v1").appending(path: "sessions")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var items: [URLQueryItem] = []
    if let limit {
      items.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    if includeArchived {
      items.append(URLQueryItem(name: "includeArchived", value: "true"))
    }
    components?.queryItems = items.isEmpty ? nil : items
    url = components?.url ?? url

    let req = HTTPRequest(url: url, method: "GET")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode([WuhuSession].self, from: data)
  }

  public func getSession(
    id: String,
    sinceCursor: Int64? = nil,
    sinceTime: Date? = nil,
  ) async throws -> WuhuGetSessionResponse {
    var url = baseURL.appending(path: "v1").appending(path: "sessions").appending(path: id)
    if sinceCursor != nil || sinceTime != nil {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      var items: [URLQueryItem] = []
      if let sinceCursor { items.append(.init(name: "sinceCursor", value: String(sinceCursor))) }
      if let sinceTime { items.append(.init(name: "sinceTime", value: String(sinceTime.timeIntervalSince1970))) }
      components?.queryItems = items.isEmpty ? nil : items
      url = components?.url ?? url
    }
    let req = HTTPRequest(url: url, method: "GET")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuGetSessionResponse.self, from: data)
  }

  public func enqueue(
    sessionID: String,
    input: String,
    user: String? = nil,
    lane: EnqueueLane = .followUp,
  ) async throws -> String {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "enqueue")

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "lane", value: lane.rawValue)]

    let author: Author = {
      let trimmed = (user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return .unknown }
      return .participant(.init(rawValue: trimmed), kind: .human)
    }()

    let message = QueuedUserMessage(author: author, content: .text(input))

    var req = HTTPRequest(url: components?.url ?? url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.body = try WuhuJSON.encoder.encode(message)

    let (data, _) = try await http.data(for: req)
    let qid = try WuhuJSON.decoder.decode(QueueItemID.self, from: data)
    return qid.rawValue
  }

  public func promptStream(
    sessionID: String,
    input: String,
    user: String? = nil,
  ) async throws -> AsyncThrowingStream<WuhuSessionStreamEvent, any Error> {
    let baseline = try await getSession(id: sessionID)
    let sinceCursor = baseline.transcript.last?.id

    _ = try await enqueue(sessionID: sessionID, input: input, user: user, lane: .followUp)
    return try await followSessionStream(
      sessionID: sessionID,
      sinceCursor: sinceCursor,
      sinceTime: nil,
      stopAfterIdle: true,
      timeoutSeconds: nil,
    )
  }

  public func followSessionStream(
    sessionID: String,
    sinceCursor: Int64? = nil,
    sinceTime: Date? = nil,
    stopAfterIdle: Bool? = nil,
    timeoutSeconds: Double? = nil,
  ) async throws -> AsyncThrowingStream<WuhuSessionStreamEvent, any Error> {
    var url = baseURL.appending(path: "v1").appending(path: "sessions").appending(path: sessionID).appending(path: "follow")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var items: [URLQueryItem] = []
    if let sinceCursor { items.append(.init(name: "sinceCursor", value: String(sinceCursor))) }
    if let sinceTime { items.append(.init(name: "sinceTime", value: String(sinceTime.timeIntervalSince1970))) }
    if let stopAfterIdle { items.append(.init(name: "stopAfterIdle", value: stopAfterIdle ? "1" : "0")) }
    if let timeoutSeconds { items.append(.init(name: "timeoutSeconds", value: String(timeoutSeconds))) }
    components?.queryItems = items.isEmpty ? nil : items
    url = components?.url ?? url

    var req = HTTPRequest(url: url, method: "GET")
    req.setHeader("text/event-stream", for: "Accept")
    let sse = try await http.sse(for: req)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await message in sse {
            guard let data = message.data.data(using: .utf8) else { continue }
            let event = try WuhuJSON.decoder.decode(WuhuSessionStreamEvent.self, from: data)
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

  public func archiveSession(sessionID: String) async throws -> WuhuArchiveSessionResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "archive")
    let req = HTTPRequest(url: url, method: "POST")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuArchiveSessionResponse.self, from: data)
  }

  public func unarchiveSession(sessionID: String) async throws -> WuhuArchiveSessionResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "unarchive")
    let req = HTTPRequest(url: url, method: "POST")
    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuArchiveSessionResponse.self, from: data)
  }

  public func stopSession(
    sessionID: String,
    user: String? = nil,
  ) async throws -> WuhuStopSessionResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "stop")
    var req = HTTPRequest(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.body = try WuhuJSON.encoder.encode(WuhuStopSessionRequest(user: user))

    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(WuhuStopSessionResponse.self, from: data)
  }
}
