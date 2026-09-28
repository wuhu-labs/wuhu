import Contract
import JSONValue

@Contract
public struct KanbanConfig: Codable, Equatable, Sendable {
  public let groupBy: String
  public let cardTitle: String
  public let sort: String?
  public let path: String?
}

@Contract
public struct ListConfig: Codable, Equatable, Sendable {
  public let path: String
  public let cardTitle: String
  public let subtitle: String?
}

@Contract
public struct WallConfig: Codable, Equatable, Sendable {
  public let path: String
  public let title: String
}

@Contract
public struct MapConfig: Codable, Equatable, Sendable {
  public let nodeID: String
  public let nodeTitle: String
  public let parentID: String
  public let root: String?
}

@Contract(discriminator: "view")
public enum DataView: Codable, Equatable, Sendable {
  case kanban(title: String?, sql: String, config: KanbanConfig)
  case list(title: String?, sql: String, config: ListConfig)
  case wall(title: String?, sql: String, config: WallConfig)
  case map(title: String?, sql: String, config: MapConfig)
}
