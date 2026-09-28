#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore

private let pageDefault = 50
private let pageMax = 500

func conversationPage(_ arguments: [JSONValue], in space: Space, reader: SessionID) async throws -> JSONValue {
  guard case let .string(id)? = arguments.first, !id.isEmpty else {
    throw ScriptError("conversation(id) wants a conversation id: a box is its agent's session id, a DM comes from dm(a, b)")
  }
  let options: OrderedDictionary<String, JSONValue> = switch arguments.dropFirst().first {
  case nil, .null?: [:]
  case let .object(fields)?: fields
  default: throw ScriptError("conversation(id, options) takes options as { after, before, limit }")
  }
  let cursor = try messageCursor(after: options["after"], before: options["before"])
  let limit = try pageLimit(options["limit"])
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
    throw ScriptError("unknown conversation: \(id)")
  } catch SessionStoreError.unknownMessage(let message) {
    throw ScriptError("unknown message in conversation \(id): \(message)")
  }
  let senders = try await Senders(page.messages, in: space)
  return .object([
    "messages": .array(page.messages.map { scriptMessage($0, senders: senders, names: names) }),
    "next": page.next.map { .string($0.rawValue) } ?? .null,
  ])
}

// A DM the reader could not read is null, like one that does not exist.
func directMessage(_ arguments: [JSONValue], in space: Space, reader: SessionID) async throws -> JSONValue {
  guard arguments.count == 2, case let .string(a) = arguments[0], case let .string(b) = arguments[1],
        !a.isEmpty, !b.isEmpty
  else { throw ScriptError("dm(a, b) wants two session ids") }
  guard let id = try await space.sessions.directMessage(between: a, and: b) else { return .null }
  let group = try await space.principal(of: reader).group
  guard try await space.sessions.reads(space.sessions.conversation(id), reader: reader.rawValue, group: group) else {
    return .null
  }
  return .string(id.rawValue)
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

private func malformedTime(_ text: String) -> ScriptError {
  ScriptError("'\(text)' is not a time; write YYYY-MM-DDTHH:MM[:SS[.fff]] and a zone, like 2026-09-26T11:00+08:00")
}

private func messageCursor(after: JSONValue?, before: JSONValue?) throws -> MessageCursor {
  switch (try cursorText(after, "after"), try cursorText(before, "before")) {
  case (nil, nil): .latest
  case let (after?, nil): .after(try messageAnchor(after))
  case let (nil, before?): .before(try messageAnchor(before))
  case (_?, _?): throw ScriptError("pass after or before, not both")
  }
}

private func cursorText(_ value: JSONValue?, _ name: String) throws -> String? {
  switch value {
  case nil, .null?: nil
  case let .string(text)?: text
  default: throw ScriptError("\(name) takes a message id or an ISO time")
  }
}

private func pageLimit(_ value: JSONValue?) throws -> Int {
  let limit: Int? = switch value {
  case nil, .null?: pageDefault
  case let .integer(number)?: number
  case let .number(number)?: number.rounded() == number && abs(number) <= 1e9 ? Int(number) : nil
  default: nil
  }
  guard let limit, (1 ... pageMax).contains(limit) else {
    throw ScriptError("limit is a whole number from 1 to \(pageMax)")
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
