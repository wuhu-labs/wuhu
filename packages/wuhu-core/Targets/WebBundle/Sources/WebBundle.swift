#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct SpaceServer.WebApp
import struct SpaceServer.WebContent

public enum WebBundle {
  public enum MissingFile: Error { case index, shell, worker }

  public static func load() throws -> WebContent {
    guard let webApp = WebApp(files: Dictionary(uniqueKeysWithValues: EmbeddedWebApp.files.map {
      ($0.path.joined(separator: "/"), Data(EmbeddedWebApp.bytes(for: $0)))
    })) else { throw MissingFile.index }
    let scripts = Dictionary(uniqueKeysWithValues: EmbeddedShellSDK.files.compactMap { file in
      file.path.count == 1 && file.path[0].hasSuffix(".js")
        ? (file.path[0], Data(EmbeddedShellSDK.bytes(for: file))) : nil
    })
    guard scripts["shell.js"] != nil else { throw MissingFile.shell }
    guard scripts["worker.js"] != nil else { throw MissingFile.worker }
    return WebContent(webApp: webApp, views: Dictionary(uniqueKeysWithValues: EmbeddedViewProviders.files.map {
      ($0.path.joined(separator: "/"), Data(EmbeddedViewProviders.bytes(for: $0)))
    }), scripts: scripts)
  }
}
