import DocIndex
import SpaceFS
import Testing

private func spacePath(_ raw: String) -> SpacePath {
  try! SpacePath(validating: raw)
}

struct DocIndexMarkdownTests {
  @Test func `title is the file basename, ignoring frontmatter and H1`() {
    let body = """
    ---
    title: A Frontmatter Title
    ---
    # An H1 Heading
    body
    """
    let doc = DocIndex.parse(markdown: body, at: spacePath("/plans/2026/new-design.md"))
    #expect(doc.title == "new-design.md")
  }

  @Test func `kind and status come from frontmatter strings, non-strings ignored`() {
    let strings = DocIndex.parse(markdown: "---\nkind: plan\nstatus: active\n---\nbody", at: spacePath("/p.md"))
    #expect(strings.kind == "plan")
    #expect(strings.status == "active")

    let nonStrings = DocIndex.parse(markdown: "---\nkind: 42\nstatus: true\n---\nbody", at: spacePath("/p.md"))
    #expect(nonStrings.kind == nil)
    #expect(nonStrings.status == nil)
  }

  @Test func `kind and status are excluded from custom attributes`() {
    let body = "---\nkind: plan\nstatus: active\nowner: morgan\n---\nbody"
    let doc = DocIndex.parse(markdown: body, at: spacePath("/p.md"))
    #expect(doc.customAttrs == [DocMeta.Attr(name: "owner", value: .scalar("\"morgan\""))])
  }

  @Test func `scalar attributes render canonical JSON by type`() {
    let body = """
    ---
    name: hello
    count: 42
    ratio: 1.5
    flag: true
    off: false
    nothing: null
    tilde: ~
    quoted: "with: colon"
    ---
    body
    """
    let doc = DocIndex.parse(markdown: body, at: spacePath("/p.md"))
    #expect(doc.customAttrs == [
      DocMeta.Attr(name: "count", value: .scalar("42")),
      DocMeta.Attr(name: "flag", value: .scalar("true")),
      DocMeta.Attr(name: "name", value: .scalar("\"hello\"")),
      DocMeta.Attr(name: "nothing", value: .scalar("null")),
      DocMeta.Attr(name: "off", value: .scalar("false")),
      DocMeta.Attr(name: "quoted", value: .scalar("\"with: colon\"")),
      DocMeta.Attr(name: "ratio", value: .scalar("1.5")),
      DocMeta.Attr(name: "tilde", value: .scalar("null")),
    ])
  }

  @Test func `large integers are kept exact, not coerced through Double`() {
    let doc = DocIndex.parse(markdown: "---\nbig: 9007199254740993\n---\nbody", at: spacePath("/p.md"))
    #expect(doc.customAttrs == [DocMeta.Attr(name: "big", value: .scalar("9007199254740993"))])
  }

  @Test func `a scalar array is kept as an array of canonical JSON elements`() {
    let doc = DocIndex.parse(markdown: "---\ntags: [alpha, beta, 3, true, null]\n---\nbody", at: spacePath("/p.md"))
    #expect(doc.customAttrs == [
      DocMeta.Attr(name: "tags", value: .array(["\"alpha\"", "\"beta\"", "3", "true", "null"])),
    ])
  }

  @Test func `an empty array contributes no attribute`() {
    let doc = DocIndex.parse(markdown: "---\ntags: []\nkeep: kept\n---\nbody", at: spacePath("/p.md"))
    #expect(doc.customAttrs == [DocMeta.Attr(name: "keep", value: .scalar("\"kept\""))])
  }

  @Test func `YAML 1.1 boolean-like scalars parse as booleans, unlike a string scanner`() {
    let doc = DocIndex.parse(markdown: "---\nbare: yes\nquoted: 'no'\n---\nbody", at: spacePath("/p.md"))
    #expect(doc.customAttrs == [
      DocMeta.Attr(name: "bare", value: .scalar("true")),
      DocMeta.Attr(name: "quoted", value: .scalar("\"no\"")),
    ])
  }

  @Test func `an object attribute renders as canonical JSON with sorted keys`() {
    let body = """
    ---
    template:
      prefix: "log-"
      naming: date
      pad: 2
    ---
    body
    """
    let doc = DocIndex.parse(markdown: body, at: spacePath("/p.md"))
    #expect(doc.customAttrs == [
      DocMeta.Attr(name: "template", value: .jsonObject(#"{"naming":"date","pad":2,"prefix":"log-"}"#)),
    ])
  }

  @Test func `broken YAML frontmatter yields no attributes but the body is still parsed`() {
    let body = "---\nkind: [unclosed\n: : :\n---\nsee [a](notes/a.md)"
    let doc = DocIndex.parse(markdown: body, at: spacePath("/p.md"))
    #expect(doc.kind == nil)
    #expect(doc.customAttrs.isEmpty)
    #expect(doc.links == [spacePath("/notes/a.md")])
  }

  @Test func `a document without frontmatter has no attributes`() {
    let doc = DocIndex.parse(markdown: "# Title\n\nbody", at: spacePath("/p.md"))
    #expect(doc.kind == nil)
    #expect(doc.status == nil)
    #expect(doc.customAttrs.isEmpty)
  }

  @Test func `CRLF frontmatter and an ellipsis close fence are honored`() {
    let crlf = DocIndex.parse(markdown: "---\r\nkind: plan\r\nowner: m\r\n---\r\nbody", at: spacePath("/p.md"))
    #expect(crlf.kind == "plan")
    #expect(crlf.customAttrs == [DocMeta.Attr(name: "owner", value: .scalar("\"m\""))])

    let ellipsis = DocIndex.parse(markdown: "---\nkind: plan\n...\nbody", at: spacePath("/p.md"))
    #expect(ellipsis.kind == "plan")
  }

  @Test func `markdown links resolve to absolute paths, externals dropped`() {
    let body = """
    see [rel](notes/a.md), [abs](/plans/b.md), [up](../shared/c.md),
    [ext](https://example.com), [mail](mailto:x@y.com) and ![logo](img/logo.png)
    """
    let doc = DocIndex.parse(markdown: body, at: spacePath("/space/todo.md"))
    #expect(doc.links == [
      spacePath("/space/notes/a.md"),
      spacePath("/plans/b.md"),
      spacePath("/shared/c.md"),
      spacePath("/space/img/logo.png"),
    ])
  }

  @Test func `a group link takes only a host the file tools take`() {
    let body = "[a](wuhu://Alice.localspace/x.md), [b](wuhu://foo_bar.localspace/y.md), [c](wuhu://a.b.localspace/z.md), [d](wuhu://localspace/w.md)"
    let doc = DocIndex.parse(markdown: body, at: spacePath("/p.md"))
    #expect(doc.groupLinks == [DocMeta.GroupLink(group: "alice", path: spacePath("/x.md"))])
    #expect(doc.links.isEmpty)
  }

  @Test func `an empty document parses to an empty result`() {
    let doc = DocIndex.parse(markdown: "", at: spacePath("/empty.md"))
    #expect(doc == DocMeta(title: "empty.md", kind: nil, status: nil, customAttrs: [], links: []))
  }

  @Test func `a top-level array of objects multiplies into canonical-JSON element rows`() {
    let body = "---\nsteps:\n  - {do: a}\n  - {do: b}\n---\nbody"
    let doc = DocIndex.parse(markdown: body, at: spacePath("/p.md"))
    #expect(doc.customAttrs == [
      DocMeta.Attr(name: "steps", value: .array(["{\"do\":\"a\"}", "{\"do\":\"b\"}"])),
    ])
  }

  @Test func `a heterogeneous array keeps scalar siblings scalar and non-scalars as canonical JSON`() {
    let doc = DocIndex.parse(markdown: "---\ntags: [alpha, {x: 1}]\n---\nbody", at: spacePath("/p.md"))
    #expect(doc.customAttrs == [
      DocMeta.Attr(name: "tags", value: .array(["\"alpha\"", "{\"x\":1}"])),
    ])
  }

  @Test func `a non-scalar mapping key degrades instead of trapping the process`() {
    // "[ref]: x" between two fences is a YAML flow-sequence key; Yams' mapping
    // constructor force-unwraps a String from it and traps. compose + our walk skip it.
    let doc = DocIndex.parse(markdown: "---\n[ref]: x\n---\nbody", at: spacePath("/p.md"))
    #expect(doc.kind == nil)
    #expect(doc.customAttrs.isEmpty)
  }

  @Test func `a timestamp scalar keeps the author's text as a string`() {
    let doc = DocIndex.parse(markdown: "---\ndate: 2026-07-03\n---\nbody", at: spacePath("/p.md"))
    #expect(doc.customAttrs == [DocMeta.Attr(name: "date", value: .scalar("\"2026-07-03\""))])
  }

  @Test func `a binary-tagged scalar keeps the author's text as a string`() {
    let doc = DocIndex.parse(markdown: "---\nblob: !!binary aGk=\n---\nbody", at: spacePath("/p.md"))
    #expect(doc.customAttrs == [DocMeta.Attr(name: "blob", value: .scalar("\"aGk=\""))])
  }

  @Test func `non-finite floats stay strings so payloads remain valid JSON`() {
    let doc = DocIndex.parse(markdown: "---\nposinf: .inf\nneginf: -.inf\nnotnum: .nan\n---\nbody", at: spacePath("/p.md"))
    #expect(doc.customAttrs == [
      DocMeta.Attr(name: "neginf", value: .scalar("\"-.inf\"")),
      DocMeta.Attr(name: "notnum", value: .scalar("\".nan\"")),
      DocMeta.Attr(name: "posinf", value: .scalar("\".inf\"")),
    ])
  }

  @Test func `percent-encoded link destinations decode before resolution`() {
    let doc = DocIndex.parse(markdown: "[a](my%20file.md) and [b](sub%20dir/x.md)", at: spacePath("/dir/doc.md"))
    #expect(doc.links == [spacePath("/dir/my file.md"), spacePath("/dir/sub dir/x.md")])
  }

  @Test func `a fragment or query is stripped before decoding, and an encoded colon is not a scheme`() {
    let doc = DocIndex.parse(
      markdown: "[a](notes/a.md#section) [b](notes/b.md?x=1) [c](my%3Afile.md)",
      at: spacePath("/s/doc.md"),
    )
    #expect(doc.links == [spacePath("/s/notes/a.md"), spacePath("/s/notes/b.md"), spacePath("/s/my:file.md")])
  }
}

struct DocIndexHTMLTests {
  @Test func `the HTML title element is ignored for the title`() {
    let doc = DocIndex.parse(html: "<html><head><title>Ignored</title></head><body>x</body></html>", at: spacePath("/page.html"))
    #expect(doc.title == "page.html")
  }

  @Test func `kind and status come from reserved meta tags, matched exactly and case-sensitively`() {
    let matched = DocIndex.parse(
      html: #"<meta name="wuhu:kind" content="report"><meta name="wuhu:status" content="draft">"#,
      at: spacePath("/r.html"),
    )
    #expect(matched.kind == "report")
    #expect(matched.status == "draft")

    let mismatched = DocIndex.parse(
      html: #"<META NAME="WUHU:KIND" content="report"><meta name="Wuhu:Status" content="draft">"#,
      at: spacePath("/r.html"),
    )
    #expect(mismatched.kind == nil)
    #expect(mismatched.status == nil)
  }

  @Test func `custom meta names match the prefix case-sensitively and keep the suffix case`() {
    let body = #"""
    <meta name="wuhu-custom:Owner" content="a">
    <meta name="WUHU-CUSTOM:owner" content="b">
    """#
    let doc = DocIndex.parse(html: body, at: spacePath("/r.html"))
    #expect(doc.customAttrs == [DocMeta.Attr(name: "Owner", value: .scalar("\"a\""))])
  }

  @Test func `a base element's own href is not captured and base-relative resolution is not applied`() {
    let body = #"<base href="/assets/base.md"><a href="doc.md">a</a>"#
    let doc = DocIndex.parse(html: body, at: spacePath("/p/index.html"))
    #expect(doc.links == [spacePath("/p/doc.md")])
  }

  @Test func `custom metas become string EAV rows, repeated names yield multiple rows`() {
    let body = #"""
    <meta name="wuhu-custom:owner" content="morgan">
    <meta name="wuhu-custom:priority" content="3">
    <meta name="wuhu-custom:tag" content="alpha">
    <meta name="wuhu-custom:tag" content="beta">
    """#
    let doc = DocIndex.parse(html: body, at: spacePath("/r.html"))
    #expect(doc.customAttrs == [
      DocMeta.Attr(name: "owner", value: .scalar("\"morgan\"")),
      DocMeta.Attr(name: "priority", value: .scalar("\"3\"")),
      DocMeta.Attr(name: "tag", value: .scalar("\"alpha\"")),
      DocMeta.Attr(name: "tag", value: .scalar("\"beta\"")),
    ])
  }

  @Test func `an empty custom attribute name is dropped`() {
    let doc = DocIndex.parse(html: #"<meta name="wuhu-custom:" content="x">"#, at: spacePath("/r.html"))
    #expect(doc.customAttrs.isEmpty)
  }

  @Test func `anchor, image, link and script targets are captured in document order, externals dropped`() {
    let body = """
    <a href="/plans/a.md">a</a>
    <a href="https://example.com">ext</a>
    <img src="img/logo.png">
    <link href="styles.css">
    <script src="app.js"></script>
    """
    let doc = DocIndex.parse(html: body, at: spacePath("/p.html"))
    #expect(doc.links == [
      spacePath("/plans/a.md"),
      spacePath("/img/logo.png"),
      spacePath("/styles.css"),
      spacePath("/app.js"),
    ])
  }

  @Test func `links inside comments and script bodies are not captured`() {
    let body = """
    <a href="/real.md">real</a>
    <!-- <a href="/commented.md">no</a> -->
    <script>var s = '<a href="/inscript.md">no</a>';</script>
    <a href="/after.md">after</a>
    """
    let doc = DocIndex.parse(html: body, at: spacePath("/p.html"))
    #expect(doc.links == [spacePath("/real.md"), spacePath("/after.md")])
  }
}

private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

struct DocIndexPropertyTests {
  @Test func `parsing arbitrary bytes never crashes and every link is a valid SpacePath`() {
    var generator = SeededGenerator(state: 0xDEAD_BEEF_CAFE_F00D)
    let path = spacePath("/space/fuzz.md")
    for _ in 0 ..< 400 {
      let length = Int.random(in: 0 ... 320, using: &generator)
      var bytes: [UInt8] = []
      bytes.reserveCapacity(length)
      for _ in 0 ..< length { bytes.append(UInt8.random(in: 0 ... 255, using: &generator)) }
      let text = String(decoding: bytes, as: UTF8.self)

      for doc in [DocIndex.parse(markdown: text, at: path), DocIndex.parse(html: text, at: path)] {
        for link in doc.links {
          #expect((try? SpacePath(validating: link.rawValue)) != nil)
        }
      }
    }
  }

  @Test func `structured pathological nesting never crashes and induces only valid links`() {
    let path = spacePath("/space/fuzz.md")
    let cases: [String] = [
      String(repeating: ">", count: 8000) + " [x](a.md)",
      "---\nnest: " + String(repeating: "[", count: 4000) + String(repeating: "]", count: 4000) + "\n---\n",
      "---\n" + String(repeating: "  ", count: 2000) + "deep: 1\n---\n[y](b.md)",
      String(repeating: "*", count: 8000) + "emph [z](c.md)",
      "<div>" + String(repeating: "<span>", count: 8000) + "t",
    ]
    for text in cases {
      for doc in [DocIndex.parse(markdown: text, at: path), DocIndex.parse(html: text, at: path)] {
        for link in doc.links {
          #expect((try? SpacePath(validating: link.rawValue)) != nil)
        }
      }
    }
  }
}

struct DocIndexDepthTests {
  @Test func `a pathologically deep blockquote returns a DocMeta without crashing`() {
    let deep = String(repeating: ">", count: 300_000) + "x"
    let doc = DocIndex.parse(markdown: deep, at: spacePath("/deep.md"))
    #expect(doc.title == "deep.md")
    #expect(doc.links.isEmpty)
  }

  @Test func `a body past the block-quote limit drops markdown links but keeps frontmatter`() {
    let deep = "---\nkind: note\n---\n" + String(repeating: ">", count: 60000) + " [x](a.md)"
    let doc = DocIndex.parse(markdown: deep, at: spacePath("/p.md"))
    #expect(doc.kind == "note")
    #expect(doc.links.isEmpty)
  }

  @Test func `deeply nested YAML frontmatter returns a DocMeta without crashing`() {
    let depth = 50000
    let yaml = "---\nnest: " + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "\n---\nbody"
    let doc = DocIndex.parse(markdown: yaml, at: spacePath("/deep.md"))
    #expect(doc.title == "deep.md")
  }
}
