import JSONValue
import OrderedCollections

public enum SessionExecutor: Hashable, Sendable {
  case kernel(ModelSpecifier)
  // Decode-only: Start over on a kernel provider is the only way back.
  case claudeCode(ModelSpecifier)
  // Decode-only: sessions archived before contractors were removed still list,
  // but nothing creates, runs, or rewrites one.
  case contractor(name: String)
}

public struct ExecutorSpecError: Error, Hashable, Sendable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }
}

extension SessionExecutor {
  public var kind: String {
    switch self {
    case .kernel: Self.kernelKind
    case .claudeCode: Self.claudeCodeKind
    case .contractor(let name): Self.contractorPrefix + name
    }
  }

  static let kernelKind = "kernel"
  static let claudeCodeKind = "claude-code"
  static let contractorPrefix = "contractor:"

  public var configJSON: String {
    switch self {
    case .kernel(let model), .claudeCode(let model):
      JSONValue.object([
        "provider": .string(model.provider),
        "model": .string(model.model),
        "effort": .string(model.effort),
      ]).jsonString()
    case .contractor:
      // Nothing reads a contractor row's config any more.
      "{}"
    }
  }

  public init(kind: String, configJSON: String) throws {
    if kind.hasPrefix(Self.contractorPrefix) {
      self = .contractor(name: String(kind.dropFirst(Self.contractorPrefix.count)))
      return
    }
    guard let json = JSONValue.parse(configJSON), var fields = json.object else {
      throw ExecutorSpecError("executor config is not a JSON object: \(configJSON)")
    }
    switch kind {
    case Self.kernelKind:
      self = .kernel(try ModelSpecifier(envelope: &fields, kind: kind, configJSON: configJSON))
    case Self.claudeCodeKind:
      self = .claudeCode(try ModelSpecifier(envelope: &fields, kind: kind, configJSON: configJSON))
    default:
      throw ExecutorSpecError("unknown executor: \(kind)")
    }
  }
}

extension ModelSpecifier {
  fileprivate init(envelope fields: inout OrderedDictionary<String, JSONValue>, kind: String, configJSON: String) throws {
    guard let provider = fields.removeValue(forKey: "provider")?.stringValue,
          let model = fields.removeValue(forKey: "model")?.stringValue,
          let effort = fields.removeValue(forKey: "effort")?.stringValue
    else {
      throw ExecutorSpecError("\(kind) config wants string provider, model, and effort: \(configJSON)")
    }
    guard fields.isEmpty else {
      throw ExecutorSpecError("unknown \(kind) config field(s): \(fields.keys.joined(separator: ", "))")
    }
    self.init(provider: provider, model: model, effort: effort)
  }
}

public struct SessionCreationParams: Hashable, Sendable {
  public var executor: String?
  public var provider: String?
  public var model: String?
  public var effort: String?
  public var tags: [String]?

  public init(
    executor: String? = nil,
    provider: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    tags: [String]? = nil,
  ) {
    self.executor = executor
    self.provider = provider
    self.model = model
    self.effort = effort
    self.tags = tags
  }

  public func merged(over template: SessionCreationParams) -> SessionCreationParams {
    SessionCreationParams(
      executor: executor ?? template.executor,
      provider: provider ?? template.provider,
      model: model ?? template.model,
      effort: effort ?? template.effort,
      tags: tags ?? template.tags,
    )
  }

  public init(templateFields: [String: JSONValue]) throws {
    var fields = templateFields
    func string(_ key: String) throws -> String? {
      guard let value = fields.removeValue(forKey: key) else { return nil }
      guard let string = value.stringValue else {
        throw ExecutorSpecError("template \(key) must be a string")
      }
      return string
    }
    let executor = try string("executor")
    try Self.validateExecutor(executor)
    let provider = try string("provider")
    let model = try string("model")
    let effort = try string("effort")
    var tags: [String]?
    if let value = fields.removeValue(forKey: "tags") {
      guard let items = value.array, let strings = items.failableMap(\.stringValue) else {
        throw ExecutorSpecError("template tags must be an array of strings")
      }
      tags = strings
    }
    guard fields.isEmpty else {
      throw ExecutorSpecError("unknown template field(s): \(fields.keys.sorted().joined(separator: ", "))")
    }
    self.init(executor: executor, provider: provider, model: model, effort: effort, tags: tags)
  }
}

extension SessionExecutor {
  public static func resolve(
    _ params: SessionCreationParams,
    resolveModelExecutor: (String, String, String?) async throws -> SessionExecutor,
  ) async throws -> SessionExecutor {
    try SessionCreationParams.validateExecutor(params.executor)
    guard let provider = params.provider, let model = params.model else {
      throw ExecutorSpecError("a session wants provider and model")
    }
    let executor = try await resolveModelExecutor(provider, model, params.effort)
    try executor.requireSupported()
    return executor
  }
}

extension [JSONValue] {
  fileprivate func failableMap<T>(_ transform: (JSONValue) -> T?) -> [T]? {
    var result: [T] = []
    result.reserveCapacity(count)
    for element in self {
      guard let value = transform(element) else { return nil }
      result.append(value)
    }
    return result
  }
}

public struct ExecutorUnavailableError: Error, Equatable, Sendable, CustomStringConvertible {
  public init() {}
  public var description: String { "executor no longer supported" }
}

extension SessionExecutor {
  public var isRemoved: Bool {
    switch self {
    case .claudeCode, .contractor: true
    case .kernel: false
    }
  }

  public func requireSupported() throws {
    if case .claudeCode = self { throw ExecutorUnavailableError() }
  }
}

extension SessionCreationParams {
  static func validateExecutor(_ executor: String?) throws {
    if executor == "claude-code" { throw ExecutorUnavailableError() }
    guard executor == nil || executor == "kernel" else {
      throw ExecutorSpecError("unknown executor: \(executor!)")
    }
  }
}
