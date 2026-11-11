#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
import SpaceFS
import WuhuAI

/// `/_/session-transcripts/<id>/`: a session's lines as read-only files, rendered from the rows on every read. `current.jsonl` and `current.outline.txt` are the current generation's, `<generation>.jsonl` and `<generation>.outline.txt` any generation's that has lines. A session's folder is in its own group's files; the root lists nothing.
public enum SessionTranscripts {
  static let root = ["_", "session-transcripts"]

  public static func contains(_ path: String) -> Bool {
    (try? SpacePath(validating: path))?.components.starts(with: root) == true
  }
}

extension Space {
  /// The transcripts of `group`'s sessions; only paths `SessionTranscripts.contains` names resolve.
  public nonisolated func sessionTranscripts(in group: GroupID) -> any SpaceVFS {
    TranscriptFiles(store: sessions, group: group)
  }
}

struct TranscriptFiles: SpaceVFS {
  let store: SessionStore
  let group: GroupID

  private enum Node {
    case root
    case session(SessionID)
    case file(SessionID, generation: Int, outline: Bool)
  }

  private static let token = VersionToken(rev: 0)

  func read(_ path: String) async throws -> (VersionToken, Data) {
    (Self.token, try await file(path).data)
  }

  func reader(_ path: String) async throws -> any SpaceFileReader {
    SpaceDataReader(try await read(path).1)
  }

  func write(_ path: String, _: Data, ifMatch _: VersionToken?) async throws -> VersionToken {
    throw SpaceError.sentViewReadOnly(path)
  }

  func delete(_ path: String, ifMatch _: VersionToken?) async throws {
    throw SpaceError.sentViewReadOnly(path)
  }

  func move(_ path: String, to _: String) async throws {
    throw SpaceError.sentViewReadOnly(path)
  }

  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    switch try await node(path) {
    case .root:
      return (Self.token, [])
    case let .session(session):
      let (current, generations) = try await store.lineGenerations(session)
      let names = (generations.contains(current) ? ["current"] : []) + generations.map(String.init)
      var entries: [Entry] = []
      for name in names {
        for file in [name + ".jsonl", name + ".outline.txt"] {
          entries.append(try await stat(path.hasSuffix("/") ? path + file : path + "/" + file))
        }
      }
      return (Self.token, entries)
    case .file:
      throw SpaceError.notADirectory(path)
    }
  }

  func stat(_ path: String) async throws -> Entry {
    let name = (try? SpacePath(validating: path))?.lastComponent ?? ""
    guard case .file = try await node(path) else {
      return Entry(name: name, kind: .directory, size: 0, lineCount: nil, token: Self.token, mtime: Date(timeIntervalSince1970: 0))
    }
    let (data, lines) = try await file(path)
    return Entry(name: name, kind: .file, size: data.count, lineCount: lines.count, token: Self.token, mtime: lines.last?.at ?? Date(timeIntervalSince1970: 0))
  }

  private func file(_ path: String) async throws -> (data: Data, lines: [StoredTranscriptLine]) {
    guard case let .file(session, generation, outline) = try await node(path) else { throw SpaceError.notAFile(path) }
    let lines = try await store.lines(session, generation: generation)
    return (Data((outline ? Self.outline(lines) : try Self.jsonl(lines)).utf8), lines)
  }

  // A session of another group, an unknown one and a generation without
  // lines are all missing paths.
  private func node(_ path: String) async throws -> Node {
    guard let p = try? SpacePath(validating: path), p.components.starts(with: SessionTranscripts.root) else { throw SpaceError.notFound(path) }
    let rest = p.components.dropFirst(SessionTranscripts.root.count)
    guard let id = rest.first else { return .root }
    let session = SessionID(id)
    guard rest.count <= 2, let record = try? await store.record(session), record.group == group else { throw SpaceError.notFound(path) }
    guard let file = rest.dropFirst().first else { return .session(session) }
    let outline = file.hasSuffix(".outline.txt")
    guard outline || file.hasSuffix(".jsonl") else { throw SpaceError.notFound(path) }
    let stem = file.dropLast(outline ? ".outline.txt".count : ".jsonl".count)
    let (current, generations) = try await store.lineGenerations(session)
    let generation = stem == "current" ? current : Int(stem).flatMap { String($0) == stem ? $0 : nil }
    guard let generation, generations.contains(generation) else { throw SpaceError.notFound(path) }
    return .file(session, generation: generation, outline: outline)
  }
}

extension TranscriptFiles {
  static func jsonl(_ lines: [StoredTranscriptLine]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    func quoted(_ string: String) throws -> String { String(decoding: try encoder.encode(string), as: UTF8.self) }
    return try lines.map { line in
      let message = try line.shownMessage(reasoning: .dropped)
      return "{\"position\":\(line.position),\"at\":\(try quoted(line.at.formatted(.iso8601))),\"role\":\"\(line.role.rawValue)\",\"key\":\(try quoted(line.key)),\(line.meta.map { "\"meta\":\($0)," } ?? "")\"message\":\(message)}\n"
    }.joined()
  }

  static func outline(_ lines: [StoredTranscriptLine]) -> String {
    lines.map { line in
      let text = line.role == .system
        ? (try? JSONDecoder().decode([String: String].self, from: Data(line.message.utf8))["rendered"]).map(RenderedFiles.path) ?? ""
        : (try? line.shown(reasoning: .dropped)).map(summary) ?? ""
      let flat = String(text.map { $0.isNewline ? " " : $0 }.prefix(160))
      return "\(line.position) \(line.at.formatted(.iso8601)) \(line.role.rawValue) \(line.key) \(flat)\n"
    }.joined()
  }

  private static func summary(_ message: Message) -> String {
    let blocks = switch message {
    case let .user(user): user.content
    case let .assistant(assistant): assistant.content
    case let .toolResult(result): result.content
    }
    return blocks.map { block in
      switch block {
      case let .text(text): text.text
      case let .toolCall(call): "\(call.name)(\((try? JSONEncoder().encode(call.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? ""))"
      case let .media(media): "[image \(media.mimeType)]"
      case let .hostedTool(tool): "[\(tool.type) \(tool.action)]"
      case .reasoning: ""
      }
    }.filter { !$0.isEmpty }.joined(separator: " ")
  }
}

extension StoredTranscriptLine {
  public enum Reasoning: Sendable {
    case kept
    case dropped
  }

  /// The message as JSON a reader sees: an inline image is named, never inlined. A system line is as stored: it names its preamble.
  public func shownMessage(reasoning: Reasoning) throws -> String {
    guard role != .system else { return message }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(try shown(reasoning: reasoning)), as: UTF8.self)
  }

  func shown(reasoning: Reasoning) throws -> Message {
    func shown(_ blocks: [ContentBlock]) -> [ContentBlock] {
      blocks.compactMap { block in
        switch block {
        case .reasoning where reasoning == .dropped: nil
        case let .media(media) where media.url.scheme == "data": .text("[inline image \(media.mimeType), \(media.url.absoluteString.utf8.count) bytes as a data URL]")
        default: block
        }
      }
    }
    switch try JSONDecoder().decode(Message.self, from: Data(message.utf8)) {
    case var .user(user):
      user.content = shown(user.content)
      return .user(user)
    case var .assistant(assistant):
      assistant.content = shown(assistant.content)
      return .assistant(assistant)
    case var .toolResult(result):
      result.content = shown(result.content)
      return .toolResult(result)
    }
  }
}
