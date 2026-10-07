import enum MachineContract.SessionExecEnvironment

struct GroupSelection: Equatable {
  enum Source: Equatable {
    case flag
    case environment
    case config
    case none
  }

  var group: String?
  var source: Source

  static let none = Self(group: nil, source: .none)
  static let environmentName = SessionExecEnvironment.group

  static func resolve(flag: String?, environment: [String: String], config: String?) throws -> Self {
    let named = environment[Self.environmentName].flatMap { $0.isEmpty ? nil : $0 }
    if case .session = try Identity.resolve(environment: environment) {
      if flag != nil {
        throw CLIError(message: "--group is refused in a session's exec: the exec acts in its session's group")
      }
      if named != nil {
        throw CLIError(message: "\(Self.environmentName) is refused in a session's exec: the exec acts in its session's group")
      }
      return .none
    }
    if let flag { return try Self(validating: flag, source: .flag) }
    if let named { return try Self(validating: named, source: .environment) }
    if let config { return try Self(validating: config, source: .config) }
    return .none
  }

  private init(group: String?, source: Source) {
    self.group = group
    self.source = source
  }

  private init(validating group: String, source: Source) throws {
    guard isValidGroupID(group) else {
      throw UsageError(message: "\(group) (from \(Self.label(source))) is not a group id: lowercase letters, digits and inner hyphens")
    }
    self.init(group: group, source: source)
  }

  var label: String { Self.label(self.source) }

  private static func label(_ source: Source) -> String {
    switch source {
    case .flag: "--group"
    case .environment: Self.environmentName
    case .config: ".wuhu/config.json"
    case .none: "none"
    }
  }
}

func isValidGroupID(_ text: String) -> Bool {
  let segments = text.split(separator: "-", omittingEmptySubsequences: false)
  return !text.isEmpty && text.utf8.count <= 64 && segments.allSatisfy { segment in
    !segment.isEmpty && segment.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) }
  }
}

extension Command {
  var rewritesWalletGroup: Bool {
    switch self {
    case .use, .groupUse: true
    default: false
    }
  }
}

/// A command line: the global `--group <id>`, written before the verb, and the verb.
struct Invocation: Equatable {
  var group: String?
  var command: Command

  static func parse(_ arguments: [String]) throws -> Self {
    var rest = arguments[...]
    var group: String?
    while rest.first == "--group" {
      guard group == nil else { throw UsageError(message: "--group is given twice") }
      rest = rest.dropFirst()
      guard let value = rest.popFirst() else { throw UsageError(message: "--group wants a value") }
      group = value
    }
    let command = try Command.parse(Array(rest))
    if group != nil, case .use = command {
      throw UsageError(message: "use: name the group after the host: wuhu use <host:port> --group <id>")
    }
    return Self(group: group, command: command)
  }
}
