/// The base tables a statement reads through the view layer: the observation
/// region of a query.
public struct ReadTables: Hashable, Sendable {
  public let names: Set<String>

  public init(names: Set<String>) {
    self.names = names
  }
}
