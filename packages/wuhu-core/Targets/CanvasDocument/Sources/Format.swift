import LiveDocument

extension LiveFormat {
  /// `.canvas`: a board, its agent view, and the agent view's merge by id.
  public static let canvas = LiveFormat(
    configure: { CanvasSchema.configure($0) },
    text: { CanvasBoard(doc: $0).text },
    apply: { text, doc, peer, restoring in
      do { return try CanvasBoard.merge(text, into: doc, seed: peer, restoring: restoring) } catch let error as CanvasSyntaxError {
        throw LiveSyntaxError(line: error.line, reason: error.problem.description)
      }
    },
  )
}
