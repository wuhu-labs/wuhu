public struct ModelSpecifier: Hashable, Sendable, Codable {
  public var provider: String
  public var model: String
  public var effort: String

  public init(provider: String, model: String, effort: String) {
    self.provider = provider
    self.model = model
    self.effort = effort
  }
}
