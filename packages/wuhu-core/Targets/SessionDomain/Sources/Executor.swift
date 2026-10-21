import JSONValue
import OrderedCollections

public enum SessionExecutor: Hashable, Sendable, Codable {
  case kernel(ModelSpecifier)
  case modelGroup(id: String, effort: String)
  /// A session archived while it ran an executor this build does not have. Nothing creates, starts, restarts or rewrites one; its stored kind is kept because the apps label archived sessions by it.
  case retired(kind: String)
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
    case .kernel, .modelGroup: Self.kernelKind
    case let .retired(kind): kind
    }
  }

  static let kernelKind = "kernel"

  public var configJSON: String {
    switch self {
    case .kernel(let model):
      JSONValue.object([
        "provider": .string(model.provider),
        "model": .string(model.model),
        "effort": .string(model.effort),
      ]).jsonString()
    case let .modelGroup(id, effort):
      JSONValue.object(["modelGroup": .string(id), "effort": .string(effort)]).jsonString()
    case .retired:
      "{}"
    }
  }

  public init(kind: String, configJSON: String) throws {
    guard kind == Self.kernelKind else {
      self = .retired(kind: kind)
      return
    }
    guard let json = JSONValue.parse(configJSON), var fields = json.object else {
      throw ExecutorSpecError("executor config is not a JSON object: \(configJSON)")
    }
    if let group = fields.removeValue(forKey: "modelGroup") {
      guard let id = group.stringValue, !id.isEmpty,
            let effort = fields.removeValue(forKey: "effort")?.stringValue, fields.isEmpty
      else {
        throw ExecutorSpecError("kernel group config wants only string modelGroup and effort")
      }
      self = .modelGroup(id: id, effort: effort)
    } else {
      self = .kernel(try ModelSpecifier(envelope: &fields, kind: kind, configJSON: configJSON))
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
  public var modelGroup: String?
  public var provider: String?
  public var model: String?
  public var effort: String?
  public var tags: [String]?

  public init(
    executor: String? = nil,
    modelGroup: String? = nil,
    provider: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    tags: [String]? = nil,
  ) {
    self.executor = executor
    self.modelGroup = modelGroup
    self.provider = provider
    self.model = model
    self.effort = effort
    self.tags = tags
  }

  public func merged(over template: SessionCreationParams) -> SessionCreationParams {
    let overridesTarget = modelGroup != nil || provider != nil || model != nil
    let changesTarget = modelGroup != template.modelGroup && overridesTarget || provider != nil && provider != template.provider
    return SessionCreationParams(
      executor: executor ?? template.executor,
      modelGroup: overridesTarget ? modelGroup : template.modelGroup,
      provider: modelGroup != nil ? provider : provider ?? (template.modelGroup == nil ? template.provider : nil),
      model: modelGroup != nil ? model : model ?? (changesTarget ? nil : template.model),
      effort: effort ?? (changesTarget ? nil : template.effort),
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
    let modelGroup = try string("modelGroup")
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
    guard modelGroup == nil || (provider == nil && model == nil) else {
      throw ExecutorSpecError("modelGroup is mutually exclusive with provider/model")
    }
    self.init(executor: executor, modelGroup: modelGroup, provider: provider, model: model, effort: effort, tags: tags)
  }
}

extension SessionExecutor {
  public static func resolve(
    _ params: SessionCreationParams,
    resolveModelExecutor: (String, String, String?) async throws -> SessionExecutor,
    resolveModelGroup: ((String, String?) async throws -> SessionExecutor)? = nil,
  ) async throws -> SessionExecutor {
    try SessionCreationParams.validateExecutor(params.executor)
    if let group = params.modelGroup {
      guard params.provider == nil && params.model == nil else {
        throw ExecutorSpecError("modelGroup is mutually exclusive with provider/model")
      }
      guard let resolveModelGroup else { throw ExecutorSpecError("model groups are not configured") }
      let executor = try await resolveModelGroup(group, params.effort)
      try executor.requireSupported()
      return executor
    }
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
  public var isRetired: Bool {
    switch self {
    case .retired: true
    case .kernel, .modelGroup: false
    }
  }

  public func requireSupported() throws {
    if case .retired = self { throw ExecutorUnavailableError() }
  }
}

extension SessionCreationParams {
  static func validateExecutor(_ executor: String?) throws {
    guard executor == nil || executor == "kernel" else {
      throw ExecutorSpecError("unknown executor: \(executor!)")
    }
  }
}
