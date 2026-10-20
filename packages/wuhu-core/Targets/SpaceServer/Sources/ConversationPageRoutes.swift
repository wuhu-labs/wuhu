#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import func MainHub.jsonObject
import ServeRouting
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore

private let pageDefault = 50
private let pageMax = 500

// A session reads a conversation it can see as pages of script-shaped
// messages: `GET /v1/conversation/:id/page?after=|before=<message id or ISO
// instant>&limit=` answers `{messages, next}`; `GET /v1/dm?a=&b=` names the DM
// between two sessions as `{id}`, null when there is none the reader can see.
func addConversationPageRoutes(
  _ router: inout Router,
  space: Space,
  principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict,
) {
  router.get("/v1/conversation/:id/page") { request, parameters in
    let reader: SessionID
    switch try await principalOf(request) {
    case let .principal(resolved):
      guard case let .session(session) = resolved.actor else {
        return errorResponse(.forbidden, code: "forbidden", message: "a conversation page is read by a session")
      }
      reader = session
    case let .refused(response): return response
    }
    let id = parameters["id"] ?? ""
    let query = queryValues(of: request.url)
    let cursor: MessageCursor
    let limit: Int
    do {
      cursor = try messageCursor(after: query["after"], before: query["before"])
      limit = try pageLimit(query["limit"])
    } catch let error as PageArgument {
      return errorResponse(.badRequest, code: "invalidArgument", message: error.message)
    }
    let page: MessagePage
    let names: (home: GroupID, viewer: GroupID)
    do {
      let record = try await space.sessions.conversation(ConversationID(id))
      let group = try await space.principal(of: reader).group
      names = (record.group, group)
      guard try await space.sessions.reads(record, reader: reader.rawValue, group: group) else {
        throw SessionStoreError.unknownConversation(id)
      }
      page = try await space.sessions.page(of: record.id, from: cursor, limit: limit)
    } catch SessionStoreError.unknownConversation {
      return errorResponse(.notFound, code: "notFound", message: "unknown conversation: \(id)")
    } catch SessionStoreError.unknownMessage(let message) {
      return errorResponse(.notFound, code: "notFound", message: "unknown message in conversation \(id): \(message)")
    }
    let senders = try await Senders(page.messages, in: space)
    return jsonResponse(.object([
      "messages": .array(page.messages.map { scriptMessage($0, senders: senders, names: names) }),
      "next": page.next.map { .string($0.rawValue) } ?? .null,
    ]))
  }

  router.get("/v1/dm") { request, _ in
    let reader: SessionID
    switch try await principalOf(request) {
    case let .principal(resolved):
      guard case let .session(session) = resolved.actor else {
        return errorResponse(.forbidden, code: "forbidden", message: "a DM is looked up by a session")
      }
      reader = session
    case let .refused(response): return response
    }
    let query = queryValues(of: request.url)
    guard let a = query["a"], let b = query["b"], !a.isEmpty, !b.isEmpty else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "dm takes ?a= and ?b=, two session ids")
    }
    guard let id = try await space.sessions.directMessage(between: a, and: b) else { return jsonResponse(.object(["id": .null])) }
    let group = try await space.principal(of: reader).group
    guard try await space.sessions.reads(space.sessions.conversation(id), reader: reader.rawValue, group: group) else {
      return jsonResponse(.object(["id": .null]))
    }
    return jsonResponse(.object(["id": .string(id.rawValue)]))
  }
}

private struct PageArgument: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

private func messageAnchor(_ text: String) throws -> MessageAnchor {
  guard let instant = try instant(text) else { return .message(MessageID(text)) }
  return .time(instant)
}

/// An ISO 8601 instant as people type it: seconds and fraction are optional, the zone is not. Anything shaped otherwise
/// is a message id, except a string opening with a date, which is a malformed time.
private func instant(_ text: String) throws -> Date? {
  let pattern = #/(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(?::(\d{2})(?:\.(\d+))?)?(Z|[+-]\d{2}:\d{2})/#
  guard let match = text.wholeMatch(of: pattern) else {
    guard text.prefixMatch(of: #/\d{4}-\d{2}-\d{2}/#) == nil else { throw malformedTime(text) }
    return nil
  }
  let (_, day, minute, second, fraction, zone) = match.output
  let milliseconds = String((fraction ?? "").prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
  let canonical = "\(day)T\(minute):\(second ?? "00").\(milliseconds)\(zone)"
  guard let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(canonical) else {
    throw malformedTime(text)
  }
  return date
}

private func malformedTime(_ text: String) -> PageArgument {
  PageArgument("'\(text)' is not a time; write YYYY-MM-DDTHH:MM[:SS[.fff]] and a zone, like 2026-09-26T11:00+08:00")
}

private func messageCursor(after: String?, before: String?) throws -> MessageCursor {
  switch (after, before) {
  case (nil, nil): .latest
  case let (after?, nil): .after(try messageAnchor(after))
  case let (nil, before?): .before(try messageAnchor(before))
  case (_?, _?): throw PageArgument("pass after or before, not both")
  }
}

private func pageLimit(_ value: String?) throws -> Int {
  guard let value else { return pageDefault }
  guard let limit = Int(value), (1 ... pageMax).contains(limit) else {
    throw PageArgument("limit is a whole number from 1 to \(pageMax)")
  }
  return limit
}

private struct Senders {
  var handles: [String: String]
  var titles: [SessionID: String] = [:]

  init(_ messages: [MessageRecord], in space: Space) async throws {
    handles = try await space.handlesByPrincipal()
    for session in Set(messages.compactMap(\.senderSession)) {
      titles[session] = try await space.sessions.record(session).title
    }
  }
}

// A stored time is whole milliseconds, but it can read back a hair under its
// value and the format truncates; adding half a millisecond makes it round, so
// createdAt handed back as a cursor names the stored instant.
private func scriptMessage(_ message: MessageRecord, senders: Senders, names: (home: GroupID, viewer: GroupID)) -> JSONValue {
  let createdAt = Date.ISO8601FormatStyle(
    timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: message.sender.timeZone,
  )
  return jsonObject([
    ("id", .string(message.id.rawValue)),
    ("sender", jsonObject([
      ("id", .string(message.sender.id)),
      ("handle", senders.handles[message.sender.id].map(JSONValue.string)),
      ("session", message.senderSession.map { .string($0.rawValue) }),
      ("group", .string(message.senderGroup.rawValue)),
      ("title", message.senderSession.flatMap { senders.titles[$0] }.map(JSONValue.string)),
    ])),
    ("kind", .string(message.kind.rawValue)),
    ("text", .string(message.content.text)),
    ("attachments", .array(message.content.attachments.map { .string($0.named(in: names.home, for: names.viewer).path) })),
    ("replyTarget", .some(message.replyTarget.map { .string($0.rawValue) } ?? .null)),
    ("requestId", .some(message.requestID.map { .string($0.rawValue) } ?? .null)),
    ("createdAt", .string(createdAt.format(message.createdAt.addingTimeInterval(0.0005)))),
  ])
}
