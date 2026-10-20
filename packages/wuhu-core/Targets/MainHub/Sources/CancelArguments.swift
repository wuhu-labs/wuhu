public struct CancelArguments: Decodable, Sendable {
  public var id: String

  public init(id: String) { self.id = id }
}
