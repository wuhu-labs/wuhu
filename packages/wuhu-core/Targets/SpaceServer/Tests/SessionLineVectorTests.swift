import Foundation
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Testing
import WuhuAI

// The checked-in line payloads, which the web's line view decodes: a change to
// how a stored line goes on the wire fails here before it reaches the web.
@Suite struct SessionLineVectorTests {
  struct Vector: Codable {
    let name: String
    let line: SessionLinePayload
  }

  static let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../SpaceContract/Tests/contract/session-line-vectors.json")

  static func stored(_ position: Int, _ key: String, _ message: Message) throws -> StoredTranscriptLine {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let role: TranscriptLine.Role = switch message {
    case .user: .user
    case .assistant: .assistant
    case .toolResult: .toolResult
    }
    return StoredTranscriptLine(
      position: position, at: Date(timeIntervalSince1970: 1_791_000_000 + Double(position)), role: role, key: key,
      message: String(decoding: try encoder.encode(message), as: UTF8.self), meta: nil,
    )
  }

  static func vectors() throws -> [Vector] {
    let system = StoredTranscriptLine(position: 0, at: Date(timeIntervalSince1970: 1_791_000_000), role: .system, key: "system", message: #"{"rendered":"0f3a"}"#, meta: nil)
    let lines: [(String, StoredTranscriptLine)] = try [
      ("system", system),
      ("group instructions", stored(1, "group", .user(.init(content: [.text(.init(text: "Be brief."))])))),
      ("user text", stored(3, "message:m1", .user(.init(content: [.text(.init(text: "hello"))])))),
      ("assistant reasoning, text and a tool call", stored(4, "attempt:a1", .assistant(.init(content: [
        .reasoning(.encrypted(.init(providerID: "anthropic", model: "claude", summary: "thinking it over", opaque: "c2ln"))),
        .reasoning(.unencrypted("plain thought")),
        .text(.init(text: "Reading it.")),
        .toolCall(.init(id: "c1", name: "read", arguments: .init(.object(["path": .string("/a.md")])))),
      ])))),
      ("failed tool result", stored(5, "call:c1", .toolResult(.init(toolCallId: "c1", content: [.text(.init(text: "no such file"))], isError: true)))),
      ("inline image", stored(6, "message:m2", .user(.init(content: [.media(.init(url: URL(string: "data:image/png;base64,iVBORw0K")!, mimeType: "image/png"))])))),
      ("hosted web search", stored(7, "attempt:a2", .assistant(.init(content: [
        .hostedTool(HostedToolContent(providerID: "openai", payload: .object(["type": .string("web_search_call"), "action": .object(["type": .string("search")])]))!),
      ])))),
      ("linked image", stored(8, "message:m3", .user(.init(content: [.media(.init(url: URL(string: "https://example.com/cat.png")!, mimeType: "image/jpeg"))])))),
    ]
    return try lines.map { try Vector(name: $0.0, line: SessionLinePayload($0.1)) }
  }

  @Test func checkedInVectorsAreTheServerEncoding() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let encoded = String(decoding: try encoder.encode(Self.vectors()), as: UTF8.self) + "\n"
    let onDisk = try String(contentsOf: Self.fixture, encoding: .utf8)
    #expect(onDisk == encoded, "stale session-line-vectors.json; replace it with:\n\(encoded)")
  }
}
