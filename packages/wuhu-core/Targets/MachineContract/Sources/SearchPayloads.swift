import Contract
import JSONValue

@Contract
public struct SearchMatch: Codable, Equatable, Sendable {
  public let path: String
  public let line: Int
  public let text: String
  public let context: [String]
}

@Contract
public enum SearchQuery: Codable, Equatable, Sendable {
  case grep(pattern: String, path: String?, matchLimit: Int?, entryLimit: Int?, step: String?)
  case find(glob: String, path: String?, matchLimit: Int?, entryLimit: Int?, step: String?)
}

@Contract
public struct SearchRequest: Codable, Equatable, Sendable {
  public let id: Int
  public let query: SearchQuery
}

@Contract
public enum SearchResult: Codable, Equatable, Sendable {
  case matches(matches: [SearchMatch], cursor: String?)
  case paths(paths: [String], cursor: String?)
  case error(error: MachineError)
}

@Contract
public struct SearchResponse: Codable, Equatable, Sendable {
  public let id: Int
  public let result: SearchResult
}
