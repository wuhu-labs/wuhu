import JSONValue

public enum SchemaDocument {
  public static let dialect: String = "https://json-schema.org/draft/2020-12/schema"

  // Prepend "$schema" and "title" as the first keys by splicing them onto the
  // already-ordered jsonString() output, so the emitted document stays
  // byte-for-byte deterministic without a second ordered-dictionary dependency.
  // The title only decorates the top-level document (never the inlined nested
  // schemas), which also gives json-schema-to-typescript a clean type name.
  public static func document(named name: String, schema: JSONValue) -> String {
    let body = schema.jsonString()
    precondition(body.hasPrefix("{"), "a contract schema must serialize to a JSON object")
    let head = "{\"$schema\":\"\(dialect)\",\"title\":\"\(name)\""
    if body == "{}" { return head + "}\n" }
    return head + "," + body.dropFirst() + "\n"
  }

  // Acronym runs collapse to one segment: MachineID -> machine-id, VFSOp -> vfs-op.
  public static func fileName(forType name: String) -> String {
    let characters = Array(name)
    var kebab = ""
    for (offset, character) in characters.enumerated() {
      if character.isUppercase, offset != 0 {
        let afterLower = !characters[offset - 1].isUppercase
        let beforeLower = offset + 1 < characters.count && characters[offset + 1].isLowercase
        if afterLower || beforeLower { kebab += "-" }
      }
      kebab += character.lowercased()
    }
    return kebab + ".schema.json"
  }
}
