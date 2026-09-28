import Foundation

public struct SpacePath: Hashable, Sendable, Comparable, CustomStringConvertible {
  public let rawValue: String
  public let components: [String]

  public init(validating raw: String) throws {
    let normalized = raw.precomposedStringWithCanonicalMapping
    guard normalized.hasPrefix("/") else { throw SpacePathError.notAbsolute(raw) }
    if normalized == "/" {
      self.rawValue = "/"
      self.components = []
      return
    }
    var parsed: [String] = []
    for piece in normalized.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
      let component = String(piece)
      guard SpacePath.isValidComponent(component) else {
        throw SpacePathError.invalidComponent(component, in: raw)
      }
      parsed.append(component)
    }
    self.rawValue = "/" + parsed.joined(separator: "/")
    self.components = parsed
  }

  public init(components: [String]) throws {
    let normalized = components.map { $0.precomposedStringWithCanonicalMapping }
    for component in normalized where !SpacePath.isValidComponent(component) {
      throw SpacePathError.invalidComponent(component, in: "/" + normalized.joined(separator: "/"))
    }
    self.init(uncheckedComponents: normalized)
  }

  private init(uncheckedComponents: [String]) {
    self.components = uncheckedComponents
    self.rawValue = uncheckedComponents.isEmpty ? "/" : "/" + uncheckedComponents.joined(separator: "/")
  }

  public var isRoot: Bool { components.isEmpty }

  public var lastComponent: String? { components.last }

  public var parent: SpacePath {
    components.isEmpty ? self : SpacePath(uncheckedComponents: Array(components.dropLast()))
  }

  public var isReserved: Bool {
    components.first == "_" && !(homeOwner != nil && components.count > 3 || isInsideMachineFolder)
  }

  // Machine notes are stored under the machine id; a name never contains "_".
  private var isInsideMachineFolder: Bool {
    components.count > 3 && components[1] == "machines" && components[2].hasPrefix("mc_")
  }

  public var homeOwner: String? {
    components.count >= 3 && components[0] == "_" && components[1] == "sessions" ? components[2] : nil
  }

  public func resolving(_ reference: String) -> SpacePath? {
    if reference.isEmpty || reference.hasPrefix("//") { return nil }
    let isAbsolute = reference.hasPrefix("/")
    let body = isAbsolute ? reference.dropFirst() : Substring(reference)
    var resolved = isAbsolute ? [] : components
    if !body.isEmpty {
      for piece in body.split(separator: "/", omittingEmptySubsequences: false) {
        if piece == "." { continue }
        if piece == ".." {
          if resolved.isEmpty { return nil }
          resolved.removeLast()
          continue
        }
        if piece.isEmpty { return nil }
        resolved.append(String(piece))
      }
    }
    return try? SpacePath(validating: "/" + resolved.joined(separator: "/"))
  }

  public var description: String { rawValue }

  public static func < (lhs: SpacePath, rhs: SpacePath) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  static func isValidComponent(_ component: String) -> Bool {
    if component.isEmpty || component == "." || component == ".." { return false }
    var allWhitespace = true
    for scalar in component.unicodeScalars {
      if scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value) { return false }
      switch scalar {
      case "/", "@", "%", "#", "?": return false
      default: break
      }
      if scalar.value == 0x2028 || scalar.value == 0x2029 { return false }
      if scalar.properties.generalCategory == .format { return false }
      if !scalar.properties.isWhitespace { allWhitespace = false }
    }
    return !allWhitespace
  }
}

public enum SpacePathError: Error, Equatable, Sendable {
  case notAbsolute(String)
  case invalidComponent(String, in: String)
}
