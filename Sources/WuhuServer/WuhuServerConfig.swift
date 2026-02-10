import Foundation
import Yams

public struct WuhuServerConfig: Sendable, Hashable, Codable {
  public struct LLM: Sendable, Hashable, Codable {
    public var openai: String?
    public var anthropic: String?

    public init(openai: String? = nil, anthropic: String? = nil) {
      self.openai = openai
      self.anthropic = anthropic
    }
  }

  public struct Environment: Sendable, Hashable, Codable {
    public var name: String
    public var type: String
    public var path: String

    public init(name: String, type: String, path: String) {
      self.name = name
      self.type = type
      self.path = path
    }
  }

  public struct Runner: Sendable, Hashable, Codable {
    public var name: String
    /// Host:port for the runner WebSocket server (e.g. `1.2.3.4:5531`).
    public var address: String

    public init(name: String, address: String) {
      self.name = name
      self.address = address
    }
  }

  public var llm: LLM?
  public var environments: [Environment]
  public var runners: [Runner]?
  public var databasePath: String?
  public var host: String?
  public var port: Int?

  public init(
    llm: LLM? = nil,
    environments: [Environment],
    runners: [Runner]? = nil,
    databasePath: String? = nil,
    host: String? = nil,
    port: Int? = nil,
  ) {
    self.llm = llm
    self.environments = environments
    self.runners = runners
    self.databasePath = databasePath
    self.host = host
    self.port = port
  }

  public static func load(path: String) throws -> WuhuServerConfig {
    let expanded = (path as NSString).expandingTildeInPath
    let text = try String(contentsOfFile: expanded, encoding: .utf8)
    return try YAMLDecoder().decode(WuhuServerConfig.self, from: text)
  }

  public static func defaultPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu/server.yml")
      .path
  }
}
