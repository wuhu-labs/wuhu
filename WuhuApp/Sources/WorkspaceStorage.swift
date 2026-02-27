import Foundation

// MARK: - Workspace Model

struct Workspace: Identifiable, Equatable, Codable, Hashable {
  var id: UUID
  var name: String
  var serverURL: String

  init(id: UUID = UUID(), name: String, serverURL: String) {
    self.id = id
    self.name = name
    self.serverURL = serverURL
  }

  static let `default` = Workspace(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
    name: "Local",
    serverURL: "http://localhost:8080",
  )
}

// MARK: - Workspace Storage

/// Persists workspaces and the active workspace selection in UserDefaults.
enum WorkspaceStorage {
  private static let workspacesKey = "wuhuWorkspaces"
  private static let activeWorkspaceIDKey = "wuhuActiveWorkspaceID"

  static func loadWorkspaces() -> [Workspace] {
    guard let data = UserDefaults.standard.data(forKey: workspacesKey),
          let workspaces = try? JSONDecoder().decode([Workspace].self, from: data),
          !workspaces.isEmpty
    else {
      // Migrate from legacy single-URL setting
      let legacyURL = UserDefaults.standard.string(forKey: "wuhuServerURL") ?? "http://localhost:8080"
      let ws = Workspace(name: "Local", serverURL: legacyURL)
      saveWorkspaces([ws])
      return [ws]
    }
    return workspaces
  }

  static func saveWorkspaces(_ workspaces: [Workspace]) {
    guard let data = try? JSONEncoder().encode(workspaces) else { return }
    UserDefaults.standard.set(data, forKey: workspacesKey)
  }

  static func loadActiveWorkspaceID() -> UUID? {
    guard let str = UserDefaults.standard.string(forKey: activeWorkspaceIDKey) else { return nil }
    return UUID(uuidString: str)
  }

  static func saveActiveWorkspaceID(_ id: UUID) {
    UserDefaults.standard.set(id.uuidString, forKey: activeWorkspaceIDKey)
  }
}
