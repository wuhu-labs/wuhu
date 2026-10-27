#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import DocIndex
import JSONValue
import Mustache
import OrderedCollections
import struct SpaceContract.PromptSession
import enum SpaceContract.SessionKindPayload

public struct InstructionSourceFailure: Error, Equatable, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }
}

/// Renders instruction files (AGENTS.md and what they include) as Mustache
/// templates for one session. A file's frontmatter is dropped; its
/// `wuhu_queries: {name: SELECT …}` run as the session and bind `name` to
/// their rows. A missing partial, a failing query or a syntax error renders
/// one inline error line in its place, never a failure.
public struct InstructionRenderer: Sendable {
  /// One of main's tools as the session: `read` for partials, `query` for queries.
  public typealias Tool = @Sendable (_ name: String, _ input: JSONValue) async throws(InstructionSourceFailure) -> JSONValue

  public let session: PromptSession
  /// The revision space partials are read at; nil reads the latest.
  let rev: Int?
  let tool: Tool

  static let partialDepth = 8

  public init(session: PromptSession, rev: Int?, tool: @escaping Tool) {
    self.session = session
    self.rev = rev
    self.tool = tool
  }

  /// `text`, the file at `path`, rendered. A partial `{{> /x}}` is the space
  /// path `/x`; `{{> x}}` resolves from the folder of the file that includes
  /// it, wherever that file lives; a full address is itself.
  public func render(_ text: String, path: String) async -> String {
    await render(text, path: path, scope: Mustache.Scope(["session": session.templateValue]), including: [])
  }

  private func render(_ text: String, path: String, scope: Mustache.Scope, including: [String]) async -> String {
    let (yaml, body) = Templates.splitFrontmatter(text)
    let template: Mustache
    do { template = try Mustache(yaml == nil ? body : String(body.drop { $0 == "\n" })) } catch { return errorLine(path, error.message) }
    var names: OrderedDictionary<String, JSONValue> = [:]
    var failures: [String: String] = [:]
    var lead = ""
    switch Self.declared("wuhu_queries", in: text, yaml: yaml) {
    case .none: break
    case let .failure(message): lead = errorLine(path, message) + "\n"
    case let .value(.object(queries)):
      for (name, sql) in queries {
        guard case let .string(sql) = sql else {
          failures[name] = errorLine(path, "query \(name) is not SQL text")
          continue
        }
        do { names[name] = .array(try await rows(sql)) } catch { failures[name] = errorLine(path, "query \(name): \(error.message)") }
      }
    case .value: lead = errorLine(path, "wuhu_queries is not a map of names to SQL") + "\n"
    }
    let rendered = await template.render(scope.adding(names, failures: failures)) { name, scope in
      await partial(name, from: path, scope: scope, including: including + [path])
    }
    return lead + rendered
  }

  private func partial(_ name: String, from path: String, scope: Mustache.Scope, including: [String]) async -> String {
    let address = if name.hasPrefix("/") || name.contains("://") { name } else { Self.folder(of: path) + "/" + name }
    guard !including.contains(address) else { return errorLine(path, "partial \(name) includes itself through \(path)") + "\n" }
    guard including.count <= Self.partialDepth else { return errorLine(path, "partial \(name) nests deeper than \(Self.partialDepth)") + "\n" }
    do {
      return await render(try await read(address), path: address, scope: scope, including: including)
    } catch {
      return errorLine(path, "partial \(name): \(error.message)") + "\n"
    }
  }

  private func read(_ address: String) async throws(InstructionSourceFailure) -> String {
    var input: OrderedDictionary<String, JSONValue> = ["path": .string(address)]
    let space = address.hasPrefix("/") || (address.hasPrefix("wuhu://") && !address.hasPrefix("wuhu://system/"))
    if let rev, space { input["rev"] = .integer(rev) }
    guard case let .object(output) = try await tool("read", .object(input)), case let .string(content)? = output["content"] else {
      throw InstructionSourceFailure("\(address) is not a text file")
    }
    return content
  }

  private func rows(_ sql: String) async throws(InstructionSourceFailure) -> [JSONValue] {
    guard case let .object(output) = try await tool("query", .object(["sql": .string(sql)])),
          case let .array(columns)? = output["columns"], case let .array(rows)? = output["rows"]
    else { throw InstructionSourceFailure("the query returned no rows") }
    let names = columns.map { if case let .string(name) = $0 { name } else { "" } }
    return rows.map { row in
      guard case let .array(cells) = row else { return .object([:]) }
      return .object(OrderedDictionary(zip(names, cells), uniquingKeysWith: { first, _ in first }))
    }
  }

  private static func folder(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }

  private func errorLine(_ path: String, _ message: String) -> String {
    "(template error in \(path): \(message))"
  }

  enum Declared {
    case none
    case value(JSONValue)
    case failure(String)
  }

  // YAML is parsed only for a frontmatter that declares `key`, so a file whose
  // other keys are loose YAML renders as it always did.
  static func declared(_ key: String, in text: String, yaml: String?) -> Declared {
    guard let yaml, yaml.split(separator: "\n").contains(where: { $0.hasPrefix("\(key):") }) else { return .none }
    do {
      return try Frontmatter.attributes(of: Data(text.utf8))[key].map(Declared.value) ?? .none
    } catch let error as FrontmatterError {
      switch error {
      case let .malformed(message), let .unsupported(message), let .invalid(message): return .failure("frontmatter: \(message)")
      }
    } catch {
      return .failure("frontmatter: \(error)")
    }
  }
}

/// A skill's `wuhu_when`: which sessions list it. Keys AND, a key's items OR,
/// `model` items are globs; a skill without one is always listed. It filters
/// the listing only: a hidden skill stays readable.
public enum SkillCondition: Hashable, Sendable {
  case always
  case when(kinds: [SessionKindPayload]?, tags: [String]?, models: [String]?)
  /// Listed, with the error, so a broken condition never hides a skill.
  case malformed(String)

  public init(skill markdown: String) {
    switch InstructionRenderer.declared("wuhu_when", in: markdown, yaml: Templates.splitFrontmatter(markdown).yaml) {
    case .none: self = .always
    case let .failure(message): self = .malformed(message)
    case let .value(.object(fields)):
      var kinds: [SessionKindPayload]?, tags: [String]?, models: [String]?
      for (key, value) in fields {
        let items: [String]
        switch value {
        case let .string(item): items = [item]
        case let .array(values):
          items = values.compactMap { if case let .string(item) = $0 { item } else { nil } }
          guard items.count == values.count else { self = .malformed("wuhu_when.\(key) lists something other than text"); return }
        default: self = .malformed("wuhu_when.\(key) is neither text nor a list"); return
        }
        switch key {
        case "kind":
          let parsed = items.compactMap(SessionKindPayload.init(rawValue:))
          guard parsed.count == items.count else { self = .malformed("wuhu_when.kind is task or agent"); return }
          kinds = parsed
        case "tags": tags = items
        case "model": models = items
        default: self = .malformed("wuhu_when has no key \(key)"); return
        }
      }
      self = .when(kinds: kinds, tags: tags, models: models)
    case .value: self = .malformed("wuhu_when is not a map")
    }
  }

  public func shows(_ session: PromptSession) -> Bool {
    guard case let .when(kinds, tags, models) = self else { return true }
    if let kinds, !kinds.contains(session.kind) { return false }
    if let tags, Set(tags).isDisjoint(with: session.tags) { return false }
    if let models {
      guard let model = session.model, models.contains(where: { glob($0, matches: model) }) else { return false }
    }
    return true
  }
}

private func glob(_ pattern: String, matches text: String) -> Bool {
  func match(_ pattern: ArraySlice<Character>, _ text: ArraySlice<Character>) -> Bool {
    guard let head = pattern.first else { return text.isEmpty }
    switch head {
    case "*": return match(pattern.dropFirst(), text) || (!text.isEmpty && match(pattern, text.dropFirst()))
    case "?": return !text.isEmpty && match(pattern.dropFirst(), text.dropFirst())
    default: return text.first == head && match(pattern.dropFirst(), text.dropFirst())
    }
  }
  return match(ArraySlice(pattern), ArraySlice(text))
}

extension PromptSession {
  public init(_ record: SessionRecord) {
    let model: String? = switch record.executor {
    case let .kernel(specifier): "\(specifier.provider)/\(specifier.model)"
    case let .modelGroup(id, _): id
    case .retired: nil
    }
    self.init(
      id: record.id.rawValue, title: record.title, kind: record.kind == .task ? .task : .agent,
      model: model, tags: record.tags, home: SessionHome.path(of: record.id),
    )
  }

  var templateValue: JSONValue {
    .object([
      "id": .string(id),
      "title": .string(title),
      "task": .bool(kind == .task),
      "agent": .bool(kind == .agent),
      "model": model.map(JSONValue.string) ?? .null,
      "tags": .object(OrderedDictionary(tags.map { ($0, JSONValue.bool(true)) }, uniquingKeysWith: { first, _ in first })),
      "home": .string(home),
    ])
  }
}
