import LiveDocument
import Loro

extension LiveFormat {
  /// `.wmd`: its markdown agent view over the block list.
  public static let wmd = LiveFormat(
    configure: { WmdSchema.configure($0) },
    text: { project($0).content.markdown },
    apply: { text, doc, _, _ in
      try write(text, into: doc)
      return []
    },
  )
}

private func write(_ markdown: String, into doc: LoroDoc) throws {
  let target: Content
  do throws(WmdSyntaxError) { target = try Content(markdown: markdown) } catch {
    throw LiveSyntaxError(line: error.line, reason: error.problem.description)
  }
  try apply(target, to: doc)
}

enum WmdMarkdown {
  /// The agent view's spelling of `markdown`: what a write of it reads back as.
  static func canonical(_ markdown: String) throws(WmdSyntaxError) -> String {
    try Content(markdown: markdown).markdown
  }
}
