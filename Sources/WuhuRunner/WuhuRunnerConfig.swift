import Foundation
import Yams

public struct WuhuRunnerConfig: Sendable, Hashable, Codable {
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

  public struct Listen: Sendable, Hashable, Codable {
    public var host: String?
    public var port: Int?

    public init(host: String? = nil, port: Int? = nil) {
      self.host = host
      self.port = port
    }
  }

  public var name: String
  public var connectTo: String?
  public var listen: Listen?
  public var databasePath: String?
  public var environments: [Environment]

  public init(
    name: String,
    connectTo: String? = nil,
    listen: Listen? = nil,
    databasePath: String? = nil,
    environments: [Environment],
  ) {
    self.name = name
    self.connectTo = connectTo
    self.listen = listen
    self.databasePath = databasePath
    self.environments = environments
  }

  public static func load(path: String) throws -> WuhuRunnerConfig {
    let expanded = (path as NSString).expandingTildeInPath
    let text = try String(contentsOfFile: expanded, encoding: .utf8)
    return try YAMLDecoder().decode(WuhuRunnerConfig.self, from: text)
  }

  public static func defaultPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu/runner.yml")
      .path
  }
}
