struct ScriptLimits: Sendable {
  // Server memory the engine's own memory limit never sees. This caps
  // everything one execution holds there: every unread fetched body, the output
  // window of every machine process and the output budget of every running
  // machine exec; a query result, read whole before it reaches the engine, and
  // the query tool's one result must fit in what is left.
  var bufferBytes = 64 << 20
  // What one file read or listing may serialize to, claimed from the buffer up front.
  var fileResultBytes = 24 << 20
  var listingEntries = 500

  static let standard = ScriptLimits()
}
