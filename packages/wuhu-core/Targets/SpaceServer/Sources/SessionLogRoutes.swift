import Fetch
import Foundation
import JSONValue
import Serve
import ServeRouting
import SessionDomain
import struct SpaceContract.SessionEntryOutput
import struct SpaceContract.SessionLogItem
import struct SpaceContract.SessionLogOutput
import SpaceCore

func addSessionLogRoutes(
  _ router: inout Router, space: Space, runtime: SessionRuntime,
  principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict,
) {
  let store = space.sessions

  router.get("/v1/session/:id/log") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    let query = queryValues(of: request.url)
    let level: Int
    switch query["level"] {
    case nil:
      level = 1
    case let raw?:
      guard let parsed = Int(raw), (1 ... 3).contains(parsed) else {
        return errorResponse(.badRequest, code: "invalidArgument", message: "level must be 1, 2, or 3")
      }
      level = parsed
    }
    let limit: Int
    switch query["limit"] {
    case nil:
      limit = defaultLogLimit
    case let raw?:
      guard let parsed = Int(raw), parsed > 0, parsed <= maxLogLimit else {
        return errorResponse(.badRequest, code: "invalidArgument", message: "limit must be a positive integer up to \(maxLogLimit)")
      }
      limit = parsed
    }
    do {
      let record = try await store.record(id)
      switch record.executor {
      case .kernel, .claudeCode:
        let (generation, items) = try await store.transcriptSnapshot(id)
        var upper = items.count
        if let before = query["before"] {
          switch resolveKernelRef(before, generation: generation, count: items.count, session: id.rawValue) {
          case let .index(position): upper = position
          case let .refused(response): return response
          }
        }
        let tag = kernelRefTag(id.rawValue)
        let page = (0 ..< upper)
          .filter { kernelLevel(items[$0]) <= level }
          .suffix(limit)
        return try Response.json(SessionLogOutput(
          context: await sessionContext(record, store: store, budget: runtime.budget, claudeCodeTokens: runtime.service.claudeCodeContextTokens),
          items: page.map {
            SessionLogItem(ref: "\(tag):\(generation):\($0)", receivedAt: nil, emittedAt: nil, item: itemJSON(items[$0]))
          },
        ))
      case .contractor:
        return contractorLogUnavailable
      }
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.get("/v1/session/:id/entry/:ref") { request, parameters in
    guard let id = sessionID(parameters), let ref = parameters["ref"] else {
      return unknownSession(parameters)
    }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    do {
      let record = try await store.record(id)
      switch record.executor {
      case .kernel, .claudeCode:
        let (generation, items) = try await store.transcriptSnapshot(id)
        switch resolveKernelRef(ref, generation: generation, count: items.count, session: id.rawValue) {
        case let .refused(response):
          return response
        case let .index(position):
          return try Response.json(SessionEntryOutput(
            item: SessionLogItem(ref: ref, receivedAt: nil, emittedAt: nil, item: itemJSON(items[position])),
          ))
        }
      case .contractor:
        return contractorLogUnavailable
      }
    } catch {
      return sessionErrorResponse(error)
    }
  }
}

private var contractorLogUnavailable: Response {
  errorResponse(
    .unprocessableContent,
    code: "unsupportedExecutor",
    message: "this session ran on the removed contractor executor; its log is no longer served",
  )
}

let defaultLogLimit = 50
let maxLogLimit = 500

// A deterministic per-session tag baked into kernel refs: without it, a ref
// minted for one session silently addresses another's coincident
// generation:position.
func kernelRefTag(_ session: String) -> String {
  var hash: UInt32 = 2_166_136_261
  for byte in session.utf8 {
    hash ^= UInt32(byte)
    hash = hash &* 16_777_619
  }
  return String(format: "%04x", hash & 0xFFFF)
}

func kernelLevel(_ item: TranscriptItem) -> Int {
  switch item {
  case .direct, .message, .generationHead:
    1
  case let .notification(notification):
    notification.kind == .owedReply || notification.kind == .parkReminder ? 1 : 2
  case let .assistant(entry):
    entry.content.contains(where: { if case .text = $0 { return true } else { return false } }) ? 1 : 2
  case let .toolResult(result):
    // A post IS the narrative reply; every other result is debugger material.
    switch result.payload {
    case .sendMessage, .report: 1
    default: 3
    }
  case .bookmark:
    2
  }
}

private enum RefResolution {
  case index(Int)
  case refused(Response)
}

private func resolveKernelRef(_ ref: String, generation: Int, count: Int, session: String) -> RefResolution {
  let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
  guard parts.count == 3, !parts[0].isEmpty,
        let refGeneration = Int(parts[1]), refGeneration >= 0,
        let position = Int(parts[2]), position >= 0
  else {
    return .refused(malformedRef(ref))
  }
  guard parts[0] == kernelRefTag(session) else {
    return .refused(foreignRef(ref, session: session))
  }
  guard refGeneration == generation else {
    if refGeneration < generation {
      return .refused(trimmedRef(
        ref,
        why: "generation \(refGeneration) was compacted away; the transcript is at generation \(generation)",
      ))
    }
    return .refused(unknownRef(ref, session: session))
  }
  guard position < count else { return .refused(unknownRef(ref, session: session)) }
  return .index(position)
}

private func malformedRef(_ ref: String) -> Response {
  errorResponse(.badRequest, code: "invalidArgument", message: "not a log ref: \(ref)")
}

private func unknownRef(_ ref: String, session: String) -> Response {
  errorResponse(.notFound, code: "unknownRef", message: "unknown log ref \(ref) in session \(session)")
}

private func foreignRef(_ ref: String, session: String) -> Response {
  errorResponse(
    .notFound,
    code: "unknownRef",
    message: "log ref \(ref) was not minted for session \(session); refs are session-scoped",
  )
}

private func trimmedRef(_ ref: String, why: String) -> Response {
  errorResponse(
    .gone,
    code: "trimmedRef",
    message: "log ref \(ref) is gone: \(why)",
    hint: "refs are short-lived handles; re-read the log for fresh ones",
  )
}
