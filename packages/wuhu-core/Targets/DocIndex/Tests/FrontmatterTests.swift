import DocIndex
import Foundation
import JSONValue
import OrderedCollections
import Testing

private func patch(
  _ text: String, set: OrderedDictionary<String, JSONValue> = [:], remove: [String] = [],
) throws -> String {
  String(decoding: try Frontmatter.patch(Data(text.utf8), set: set, remove: remove), as: UTF8.self)
}

private func attributes(_ text: String) throws -> OrderedDictionary<String, JSONValue> {
  try Frontmatter.attributes(of: Data(text.utf8))
}

private func refusal(_ text: String, set: OrderedDictionary<String, JSONValue> = ["x": 1]) -> FrontmatterError? {
  do {
    _ = try patch(text, set: set)
    return nil
  } catch {
    return error as? FrontmatterError
  }
}

struct FrontmatterTests {
  @Test func `untouched keys keep their bytes, comments and order`() throws {
    let text = """
    ---
    # leading comment
    title: 'Plan'   # quoted on purpose
    status: draft
    # about tags
    tags: [a, b]
    draft: true
    notes: |
      # not a comment
      keep me
    ---
    # Body

    stays byte for byte\n
    """
    let out = try patch(text, set: ["status": "done", "owner": "ms"], remove: ["draft"])
    #expect(out == """
    ---
    # leading comment
    title: 'Plan'   # quoted on purpose
    status: done
    # about tags
    tags: [a, b]
    notes: |
      # not a comment
      keep me
    owner: ms
    ---
    # Body

    stays byte for byte\n
    """)
    #expect(try attributes(out) == [
      "title": "Plan", "status": "done", "tags": ["a", "b"], "notes": "# not a comment\nkeep me\n", "owner": "ms",
    ])
  }

  @Test func `removing a key keeps the comment above the next one`() throws {
    let text = "---\na: 1\n\n# about b\nb: 2\n---\n"
    #expect(try patch(text, remove: ["a"]) == "---\n\n# about b\nb: 2\n---\n")
  }

  @Test func `strings that look like other types stay strings`() throws {
    let values: OrderedDictionary<String, JSONValue> = [
      "flag": "true", "code": "001", "date": "2026-09-28", "empty": "", "tilde": "~", "yes": "yes",
      "colon": "a: b", "hash": "a #b", "dash": "- x", "lines": "one\ntwo", "number": "1.5", "merge": "<<",
    ]
    let out = try patch("---\n---\n", set: values)
    #expect(try attributes(out) == values)
    #expect(out.contains("flag: \"true\"\n"))
    #expect(out.contains("date: \"2026-09-28\"\n"))
  }

  @Test func `typed values round-trip`() throws {
    let values: OrderedDictionary<String, JSONValue> = [
      "none": .null, "on": true, "count": 3, "ratio": 1.5, "whole": 2.0, "big": 1e20,
      "list": [1, "two", .null, ["nested"], ["k": "v"]],
      "map": ["inner": ["deep": [true, false]], "empty": [:], "none": [], "text": "x"],
      "true": "key that is a keyword",
    ]
    let out = try patch("---\ntitle: t\n---\nbody\n", set: values)
    var expected: OrderedDictionary<String, JSONValue> = ["title": "t"]
    for (key, value) in values { expected[key] = value }
    #expect(try attributes(out) == expected)
    #expect(out.hasSuffix("---\nbody\n"))
  }

  @Test func `unquoted dates and quoted scalars read as strings`() throws {
    #expect(try attributes("---\nday: 2026-09-28\nn: '12'\nm: 12\nf: .inf\nz: ~\n---\n") == [
      "day": "2026-09-28", "n": "12", "m": 12, "f": ".inf", "z": .null,
    ])
  }

  @Test func `a document without frontmatter gets one`() throws {
    #expect(try patch("# Title\nbody\n", set: ["status": "done"]) == "---\nstatus: done\n---\n# Title\nbody\n")
    #expect(try patch("# Title\r\nbody\r\n", set: ["a": 1]) == "---\r\na: 1\r\n---\r\n# Title\r\nbody\r\n")
    #expect(try patch("# Title\n", remove: ["gone"]) == "# Title\n")
    #expect(try attributes("# Title\n") == [:])
  }

  @Test func `newline style and byte order mark survive`() throws {
    let text = "\u{FEFF}---\r\na: 1\r\nb: 2\r\n---\r\nbody\r\n"
    #expect(try patch(text, set: ["a": 5, "c": "x"]) == "\u{FEFF}---\r\na: 5\r\nb: 2\r\nc: x\r\n---\r\nbody\r\n")
  }

  @Test func `a multi-line value is replaced whole`() throws {
    let text = "---\nlist:\n  - a\n  - b\nnext: 1\n---\n"
    #expect(try patch(text, set: ["list": ["c"]]) == "---\nlist:\n  - c\nnext: 1\n---\n")
    #expect(try patch(text, remove: ["list"]) == "---\nnext: 1\n---\n")
  }

  @Test func `removing an absent key changes nothing`() throws {
    let text = "---\na: 1 # keep\n---\n"
    #expect(try patch(text, remove: ["missing"]) == text)
  }

  @Test func `set and remove must not overlap`() {
    #expect(throws: FrontmatterError.invalid("keys both set and removed: a")) {
      try patch("---\na: 1\n---\n", set: ["a": 2], remove: ["a"])
    }
  }

  @Test func `constructs it cannot edit safely are refused, never normalized`() {
    #expect(refusal("---\na: 1\na: 2\n---\n") == .unsupported("duplicate keys"))
    #expect(refusal("---\nbase: &b 1\nother: *b\n---\n") == .unsupported("anchors and aliases"))
    #expect(refusal("---\nbase: &b {x: 1}\n---\n") == .unsupported("anchors and aliases"))
    #expect(refusal("---\nbase: {x: 1}\nmore:\n  <<: {y: 2}\n---\n") == .unsupported("merge keys"))
    #expect(refusal("---\n{a: 1, b: 2}\n---\n") == .unsupported("a flow-style frontmatter mapping"))
    #expect(refusal("---\na: !!str 1\n---\n") == .unsupported("tags"))
    #expect(refusal("---\na: !custom x\n---\n") == .unsupported("tags"))
    #expect(refusal("---\n!!int 1: x\n---\n") == .unsupported("tags"))
    #expect(refusal("---\n? complex\n: key\n---\n") == .unsupported("the key complex does not start its line"))
  }

  @Test func `malformed frontmatter is an error`() {
    guard case .malformed? = refusal("---\na: [1, 2\n---\n") else {
      Issue.record("an unclosed flow sequence is malformed")
      return
    }
    guard case .malformed? = refusal("---\n- a\n- b\n---\n") else {
      Issue.record("a sequence is not a mapping of keys")
      return
    }
    guard case .malformed? = refusal("---\na: 1\n") else {
      Issue.record("an unclosed frontmatter is malformed")
      return
    }
  }
}
