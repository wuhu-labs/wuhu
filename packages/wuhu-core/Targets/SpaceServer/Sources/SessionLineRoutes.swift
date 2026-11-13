import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import LoopCore
import Serve
import ServeRouting
import ServeSSE
import SessionDomain
import enum SpaceContract.SessionLineEvent
import struct SpaceContract.SessionLinePayload
import enum SpaceContract.SessionLineRole
import struct SpaceContract.SessionLinesPageOutput
import SpaceCore
import TaskLifetime

func addSessionLineRoutes(
  _ router: inout Router, space: Space, runtime: SessionRuntime,
  principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict,
) {
  @Dependency(\.continuousClock) var clock

  router.get("/v1/session/:id/lines") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    let query = queryValues(of: request.url)
    let after: TranscriptCursor?
    switch (query["generation"].map { Int($0) }, query["after"].map { Int($0) }) {
    case (nil, nil):
      after = nil
    case let ((generation?)?, (position?)?):
      after = TranscriptCursor(generation: generation, position: position)
    default:
      return errorResponse(.badRequest, code: "invalidArgument", message: "pass generation and after together as integers, or neither")
    }
    switch try await reader(of: id, request, space: space, principalOf: principalOf) {
    case let .refused(response):
      return response
    case let .principal(viewer):
      return linesStreamResponse(runtime.execution.lines(id, after: after, as: viewer), scope: runtime.streamScope, clock: clock)
    }
  }

  router.get("/v1/session/:id/lines/page") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    let query = queryValues(of: request.url)
    guard let limit = Int(query["limit"] ?? "200"), (1 ... 200).contains(limit),
          query["generation"].map({ Int($0) != nil }) ?? true,
          query["before"].map({ Int($0) != nil }) ?? true
    else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "generation and before are integers; limit is 1 to 200")
    }
    do {
      let page = try await space.sessions.lines(id, generation: query["generation"].flatMap(Int.init), before: query["before"].flatMap(Int.init), limit: limit)
      return try Response.json(SessionLinesPageOutput(generation: page.generation, lines: page.lines.map(SessionLinePayload.init), hasEarlier: page.hasEarlier))
    } catch {
      return try sessionErrorResponse(error)
    }
  }
}

private func linesStreamResponse(_ frames: AsyncStream<TranscriptTail.Outgoing>, scope: TaskScope, clock: any Clock<Duration>) -> Response {
  sseResponse("session-lines", scope: scope, clock: clock) { send in
    for await frame in frames {
      let (generation, lines) = switch frame {
      case let .reset(generation, lines): (generation, lines)
      case let .lines(generation, lines): (generation, lines)
      }
      if case .reset = frame { send(try .json(SessionLineEvent.reset(generation: generation))) }
      for line in lines { send(try .json(SessionLineEvent.line(generation: generation, line: SessionLinePayload(line)))) }
    }
  }
}

extension SessionLinePayload {
  init(_ line: StoredTranscriptLine) throws {
    let role: SessionLineRole = switch line.role {
    case .system: .system
    case .user: .user
    case .assistant: .assistant
    case .toolResult: .toolResult
    }
    try self.init(
      position: line.position, at: line.at.timeIntervalSince1970, role: role, key: line.key, prompt: line.isPrompt,
      meta: line.meta.map(json), message: json(line.shownMessage(reasoning: .kept)),
    )
  }
}

private func json(_ text: String) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}
