#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The content origin's own scripts, served at `/_/<name>.js`: the injected `shell.js`, the page service worker `worker.js`, and the modules it imports.
struct ShellSDK: Sendable {
  let scripts: [String: Data]

  #if WUHU_EMBEDDED
    static let embedded: ShellSDK? = {
      let scripts = Dictionary(uniqueKeysWithValues: EmbeddedShellSDK.files.compactMap { file in
        file.path.count == 1 && file.path[0].hasSuffix(".js")
          ? (file.path[0], Data(EmbeddedShellSDK.bytes(for: file)))
          : nil
      })
      guard scripts["shell.js"] != nil, scripts["worker.js"] != nil else {
        preconditionFailure("ShellSDK must embed shell.js and worker.js")
      }
      return ShellSDK(scripts: scripts)
    }()
  #else
    static let embedded: ShellSDK? = nil
  #endif
}
