import Foundation

struct ServerConfig: Codable, Equatable, Identifiable {
  var id: UUID
  var name: String
  var urlString: String
  var username: String?

  init(id: UUID = UUID(), name: String, urlString: String, username: String? = nil) {
    self.id = id
    self.name = name
    self.urlString = urlString
    self.username = username
  }

  var url: URL? {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed) else { return nil }
    guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return nil }
    return url
  }
}

struct AppSettings: Codable, Equatable {
  var servers: [ServerConfig]
  var selectedServerID: ServerConfig.ID?
  var username: String

  static func defaults() -> AppSettings {
    let local = ServerConfig(name: "Local", urlString: "http://127.0.0.1:5530")
    return .init(servers: [local], selectedServerID: local.id, username: "")
  }

  var selectedServer: ServerConfig? {
    guard let selectedServerID else { return servers.first }
    return servers.first { $0.id == selectedServerID } ?? servers.first
  }

  var resolvedUsername: String? {
    selectedServer?.username?.trimmedNonEmpty ?? username.trimmedNonEmpty
  }
}

extension String {
  var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
