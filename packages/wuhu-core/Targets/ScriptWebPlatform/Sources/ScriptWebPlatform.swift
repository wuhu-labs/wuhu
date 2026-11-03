/// `web.js`: the fetch, abort and timer globals both script runtimes give a script, as one JS
/// function expression from its host's primitives to those globals. Each runtime calls it from
/// its own prelude.
///
/// `modules`: the built-in modules both runtimes share, in definition order. Each takes its
/// runtime's kernel from `claim()` of `wuhu:host`, which each runtime supplies itself: `host` (its
/// host functions by name, each answering a promise), `signal`, `guarded`, `bytesOf` and `base64Of`.
public enum ScriptWebPlatform {
  public static let source: String = resource("web.js")

  public static let modules: [(name: String, source: String)] = [
    ("wuhu:ai", resource("ai.js")),
    ("wuhu:web_search", resource("web_search.js")),
    ("wuhu:session", resource("session.js")),
    ("wuhu:machine", resource("machine.js")),
  ]

  private static func resource(_ name: String) -> String {
    #if WUHU_EMBEDDED
      guard let file = EmbeddedScriptWeb.files.first(where: { $0.path == [name] }) else {
        preconditionFailure("ScriptWebPlatform must embed \(name)")
      }
      return String(decoding: EmbeddedScriptWeb.bytes(for: file), as: UTF8.self)
    #else
      return #"() => { throw new Error("the script web platform needs the Bazel-embedded resources") }"#
    #endif
  }
}
