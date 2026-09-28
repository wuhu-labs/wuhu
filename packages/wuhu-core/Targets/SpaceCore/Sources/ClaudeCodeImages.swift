import JSONValue
import OrderedCollections

// The places Claude Code 2.1.272 was measured to put base64 image bytes: the
// `data` of every base64 image block, and Read's own copy of the file.
// `replace` sees every such string; returning nil leaves it, and an entry with
// nothing replaced comes back as the same storage, uncopied.
enum ClaudeCodeImages {
  static func rewriting(
    _ entry: OrderedDictionary<String, JSONValue>,
    _ replace: (String) -> String?,
  ) -> OrderedDictionary<String, JSONValue> {
    var entry = rewritingBlocks(.object(entry), replace)?.object ?? entry
    guard var result = entry["toolUseResult"]?.object,
          var file = result["file"]?.object,
          let base64 = file["base64"]?.stringValue,
          let replaced = replace(base64)
    else { return entry }
    file["base64"] = .string(replaced)
    result["file"] = .object(file)
    entry["toolUseResult"] = .object(result)
    return entry
  }

  private static func rewritingBlocks(_ value: JSONValue, _ replace: (String) -> String?) -> JSONValue? {
    switch value {
    case let .object(fields):
      var rewritten: OrderedDictionary<String, JSONValue>?
      if fields["type"] == .string("image"),
         var source = fields["source"]?.object, source["type"] == .string("base64"),
         let data = source["data"]?.stringValue, let replaced = replace(data)
      {
        source["data"] = .string(replaced)
        rewritten = fields
        rewritten?["source"] = .object(source)
      }
      for (index, child) in fields.values.enumerated() {
        guard let child = rewritingBlocks(child, replace) else { continue }
        if rewritten == nil { rewritten = fields }
        rewritten?.values[index] = child
      }
      return rewritten.map(JSONValue.object)
    case let .array(elements):
      var rewritten: [JSONValue]?
      for (index, child) in elements.enumerated() {
        guard let child = rewritingBlocks(child, replace) else { continue }
        if rewritten == nil { rewritten = elements }
        rewritten?[index] = child
      }
      return rewritten.map(JSONValue.array)
    default:
      return nil
    }
  }
}
