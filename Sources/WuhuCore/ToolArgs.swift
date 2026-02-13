import Foundation
import PiAI

struct ToolArgumentParseError: Error, Sendable, CustomStringConvertible {
  var message: String

  var description: String {
    message
  }
}

struct ToolArgs {
  let toolName: String
  private let object: [String: Any]

  init(toolName: String, args: JSONValue) throws {
    self.toolName = toolName
    let raw = args.toAny()
    guard let object = raw as? [String: Any] else {
      throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
        toolName: toolName,
        expected: "object",
        keyPath: "",
        received: raw,
      ))
    }
    self.object = object
  }

  func requireString(_ key: String) throws -> String {
    guard let value = object[key] else {
      throw ToolArgumentParseError(message: "\(toolName) tool missing required key \"\(key)\".")
    }
    guard let s = value as? String else {
      throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
        toolName: toolName,
        expected: "string",
        keyPath: key,
        received: value,
      ))
    }
    return s
  }

  func optionalString(_ key: String) throws -> String? {
    guard let value = object[key] else { return nil }
    if value is NSNull { return nil }
    guard let s = value as? String else {
      throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
        toolName: toolName,
        expected: "string",
        keyPath: key,
        received: value,
      ))
    }
    return s
  }

  func optionalBool(_ key: String) throws -> Bool? {
    guard let value = object[key] else { return nil }
    if value is NSNull { return nil }
    guard let b = value as? Bool else {
      throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
        toolName: toolName,
        expected: "boolean",
        keyPath: key,
        received: value,
      ))
    }
    return b
  }

  func optionalInt(_ key: String) throws -> Int? {
    guard let value = object[key] else { return nil }
    if value is NSNull { return nil }

    if let i = value as? Int { return i }
    if let d = value as? Double {
      guard d.isFinite else {
        throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
          toolName: toolName,
          expected: "number",
          keyPath: key,
          received: value,
        ))
      }
      let rounded = d.rounded()
      guard rounded == d, rounded >= Double(Int.min), rounded <= Double(Int.max) else {
        throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
          toolName: toolName,
          expected: "integer",
          keyPath: key,
          received: value,
        ))
      }
      return Int(rounded)
    }

    throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
      toolName: toolName,
      expected: "number",
      keyPath: key,
      received: value,
    ))
  }

  func optionalDouble(_ key: String) throws -> Double? {
    guard let value = object[key] else { return nil }
    if value is NSNull { return nil }
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
      toolName: toolName,
      expected: "number",
      keyPath: key,
      received: value,
    ))
  }

  func optionalStringArray(_ key: String) throws -> [String]? {
    guard let value = object[key] else { return nil }
    if value is NSNull { return nil }
    guard let arr = value as? [Any] else {
      throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
        toolName: toolName,
        expected: "array",
        keyPath: key,
        received: value,
      ))
    }

    var out: [String] = []
    out.reserveCapacity(arr.count)
    for (idx, element) in arr.enumerated() {
      guard let s = element as? String else {
        throw ToolArgumentParseError(message: ToolArgs.typeMismatchMessage(
          toolName: toolName,
          expected: "string",
          keyPath: "\(key)[\(idx)]",
          received: element,
        ))
      }
      out.append(s)
    }
    return out
  }

  func ensureNoExtraKeys(allowed: Set<String>) throws {
    let extras = Set(object.keys).subtracting(allowed)
    guard !extras.isEmpty else { return }
    let extra = extras.sorted().first!
    let allowedList = allowed.sorted().joined(separator: ", ")
    throw ToolArgumentParseError(message: "\(toolName) tool received unknown key \"\(extra)\". Allowed keys: \(allowedList).")
  }

  private static func typeMismatchMessage(
    toolName: String,
    expected: String,
    keyPath: String,
    received: Any,
  ) -> String {
    let path = keyPath.isEmpty ? "(root)" : keyPath
    return "\(toolName) tool expects \(expected) for key path \"\(path)\", but value \"\(formatValue(received))\" of \(typeName(received)) received."
  }

  private static func typeName(_ any: Any) -> String {
    if any is NSNull { return "null" }
    if any is Bool { return "boolean" }
    if any is Double || any is Int || any is Float { return "number" }
    if any is String { return "string" }
    if any is [Any] { return "array" }
    if any is [String: Any] { return "object" }
    return String(describing: type(of: any))
  }

  private static func formatValue(_ any: Any) -> String {
    if any is NSNull { return "null" }
    if let b = any as? Bool { return b ? "true" : "false" }
    if let d = any as? Double {
      if d.rounded() == d { return String(Int(d)) }
      return String(d)
    }
    if let i = any as? Int { return String(i) }
    if let s = any as? String { return s }
    if let obj = any as? [String: Any],
       let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8)
    {
      return text
    }
    if let arr = any as? [Any],
       let data = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8)
    {
      return text
    }
    return String(describing: any)
  }
}
