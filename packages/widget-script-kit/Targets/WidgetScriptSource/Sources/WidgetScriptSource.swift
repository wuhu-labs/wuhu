import Foundation

public enum WidgetScriptSource {
  public static func prelude() throws -> String { try source("prelude") }
  public static func catalog() throws -> String { try source("tree") }

  private static func source(_ name: String) throws -> String {
    #if WUHU_EMBEDDED
      // Bazel embeds immutable source bytes; unhosted tests do not assemble dependency resource bundles.
      let file = EmbeddedWidgetScripts.files.first { $0.path == ["\(name).js"] }!
      return String(decoding: EmbeddedWidgetScripts.bytes(for: file), as: UTF8.self)
    #else
      // SwiftPM packages the same canonical files as ordinary resources.
      let url = Bundle.module.url(forResource: name, withExtension: "js")!
      return try String(contentsOf: url, encoding: .utf8)
    #endif
  }
}
