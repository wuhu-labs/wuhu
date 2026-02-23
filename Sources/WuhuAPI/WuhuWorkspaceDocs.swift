import Foundation
import PiAI

public struct WuhuWorkspaceDocSummary: Sendable, Hashable, Codable, Identifiable {
  public var path: String
  public var frontmatter: [String: JSONValue]

  public var id: String {
    path
  }

  public init(path: String, frontmatter: [String: JSONValue]) {
    self.path = path
    self.frontmatter = frontmatter
  }
}

public struct WuhuWorkspaceDoc: Sendable, Hashable, Codable {
  public var path: String
  public var frontmatter: [String: JSONValue]
  public var body: String

  public init(path: String, frontmatter: [String: JSONValue], body: String) {
    self.path = path
    self.frontmatter = frontmatter
    self.body = body
  }
}
