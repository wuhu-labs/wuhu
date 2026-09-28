import JSONValue

extension JSONValue {
  /// Parse text as a JSON object. Tool schemas and tool-call arguments are
  /// object-shaped by contract; top-level scalars should not silently change
  /// those wire shapes.
  static func parseObject(_ text: String) -> JSONValue? {
    guard case let .object(object) = JSONValue.parse(text) else { return nil }
    return .object(object)
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  subscript(caseInsensitive key: String) -> JSONValue? {
    if let value = self[key] { return value }
    let lower = key.lowercased()
    for (k, v) in self where k.lowercased() == lower { return v }
    return nil
  }
}
