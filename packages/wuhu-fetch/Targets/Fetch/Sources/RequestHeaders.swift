import HTTPTypes

public struct RequestHeaders: Sendable {
  public private(set) var values: [String: String]
  public private(set) var sensitiveValues: [String: String]

  public init(
    values: [String: String] = [:],
    sensitiveValues: [String: String] = [:],
  ) {
    let values = Self.canonicalHeaders(values)
    let sensitiveValues = Self.canonicalHeaders(sensitiveValues)
    precondition(
      values.keys.allSatisfy { sensitiveValues[$0] == nil },
      "A header cannot be both sensitive and non-sensitive.",
    )
    self.values = values
    self.sensitiveValues = sensitiveValues
  }

  public init(_ fields: Headers) {
    self.init(values: fields.dictionaryByCanonicalName)
  }

  public subscript(_ name: String) -> String? {
    get { self.values[Self.canonicalName(name)] }
    set { self.set(name, newValue) }
  }

  public subscript(_ name: HTTPField.Name) -> String? {
    get { self.values[name.canonicalName] }
    set { self.set(name, newValue) }
  }

  public mutating func set(_ name: String, _ value: String?) {
    self.set(canonicalName: Self.canonicalName(name), value, sensitive: false)
  }

  public mutating func set(_ name: HTTPField.Name, _ value: String?) {
    self.set(canonicalName: name.canonicalName, value, sensitive: false)
  }

  public mutating func setSensitive(_ name: String, _ value: String?) {
    self.set(canonicalName: Self.canonicalName(name), value, sensitive: true)
  }

  public mutating func setSensitive(_ name: HTTPField.Name, _ value: String?) {
    self.set(canonicalName: name.canonicalName, value, sensitive: true)
  }

  public mutating func merge(_ headers: RequestHeaders) {
    for (name, value) in headers.values {
      self.set(name, value)
    }
    for (name, value) in headers.sensitiveValues {
      self.setSensitive(name, value)
    }
  }

  public var fields: Headers {
    Headers(self.values)
  }

  private mutating func set(canonicalName: String, _ value: String?, sensitive: Bool) {
    guard let value else {
      self.values[canonicalName] = nil
      self.sensitiveValues[canonicalName] = nil
      return
    }

    if sensitive {
      self.values[canonicalName] = nil
      self.sensitiveValues[canonicalName] = value
    } else {
      self.values[canonicalName] = value
      self.sensitiveValues[canonicalName] = nil
    }
  }

  private static func canonicalHeaders(_ headers: [String: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: headers.map { name, value in
      (Self.canonicalName(name), value)
    })
  }

  private static func canonicalName(_ name: String) -> String {
    guard let fieldName = HTTPField.Name(name) else {
      preconditionFailure("Invalid HTTP header name: \(name)")
    }
    return fieldName.canonicalName
  }
}

private extension Headers {
  init(_ values: [String: String]) {
    self.init()
    for (name, value) in values {
      guard let fieldName = HTTPField.Name(name) else {
        preconditionFailure("Invalid HTTP header name: \(name)")
      }
      self[fieldName] = value
    }
  }

  /// Repeated fields fold into one line: cookie crumbs (HTTP/2 splits
  /// `cookie` per pair) with "; ", any other field with ", ".
  var dictionaryByCanonicalName: [String: String] {
    var values: [String: String] = [:]
    for field in self {
      let name = field.name.canonicalName
      if let first = values[name] {
        values[name] = first + (field.name == .cookie ? "; " : ", ") + field.value
      } else {
        values[name] = field.value
      }
    }
    return values
  }
}
