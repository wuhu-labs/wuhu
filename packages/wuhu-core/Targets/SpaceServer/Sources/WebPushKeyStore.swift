import Foundation
import WebPush

struct WebPushKeyStore {
  private struct StoredKey: Codable {
    var version: Int
    var key: VAPID.Key
  }

  static func loadOrCreate(directory: URL, contact: URL) async throws -> VAPID.Configuration {
    let file = directory.appendingPathComponent("vapid.json")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let key: VAPID.Key
    if FileManager.default.fileExists(atPath: file.path) {
      let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw SymbolicWebPushKey(path: file.path) }
      key = try JSONDecoder().decode(StoredKey.self, from: Data(contentsOf: file)).key
    } else {
      key = VAPID.Key()
      try JSONEncoder().encode(StoredKey(version: 1, key: key)).write(to: file, options: .atomic)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return VAPID.Configuration(key: key, contactInformation: .url(contact))
  }
}

private struct SymbolicWebPushKey: Error {
  var path: String
}
