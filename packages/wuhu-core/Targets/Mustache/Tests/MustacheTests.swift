import JSONValue
@testable import Mustache
import OrderedCollections
import Testing

private func render(
  _ source: String,
  _ data: OrderedDictionary<String, JSONValue> = [:],
  failures: [String: String] = [:],
  partials: [String: String] = [:],
) async throws -> String {
  let template = try Mustache(source)
  return await template.render(Mustache.Scope(data, failures: failures)) { name, scope in
    guard let source = partials[name], let partial = try? Mustache(source) else { return "(no \(name))" }
    return await partial.render(scope) { name, _ in "(no \(name))" }
  }
}

struct MustacheTests {
  @Test func variablesAreNeverEscaped() async throws {
    let data: OrderedDictionary<String, JSONValue> = ["html": "<b>&</b>", "n": 3, "on": true, "none": .null]
    #expect(try await render("{{html}} {{{html}}} {{& html}} {{n}} {{on}} [{{none}}] [{{absent}}]", data) == "<b>&</b> <b>&</b> <b>&</b> 3 true [] []")
  }

  @Test func dottedNamesResolveTheirHeadInTheNearestFrame() async throws {
    let data: OrderedDictionary<String, JSONValue> = [
      "session": ["title": "coder", "tags": ["review": true]],
      "rows": [["title": "inner"]],
    ]
    #expect(try await render("{{session.title}}{{#session.tags.review}} reviews{{/session.tags.review}}", data) == "coder reviews")
    #expect(try await render("{{#rows}}{{title}}/{{session.title}}{{/rows}}", data) == "inner/coder")
    #expect(try await render("[{{session.missing.deep}}]", data) == "[]")
  }

  @Test func sectionsIterateListsAndInvertedSectionsRenderOnNothing() async throws {
    let data: OrderedDictionary<String, JSONValue> = ["rows": [["id": 1], ["id": 2]], "empty": [], "no": false, "names": ["a", "b"]]
    #expect(try await render("{{#rows}}<{{id}}>{{/rows}}", data) == "<1><2>")
    #expect(try await render("{{#names}}{{.}};{{/names}}", data) == "a;b;")
    #expect(try await render("{{^empty}}none{{/empty}}{{^no}}!{{/no}}{{^absent}}?{{/absent}}{{^rows}}x{{/rows}}", data) == "none!?")
    #expect(try await render("{{#empty}}x{{/empty}}{{#no}}x{{/no}}{{#absent}}x{{/absent}}", data) == "")
  }

  @Test func standaloneTagsTakeTheirWholeLine() async throws {
    let source = """
    Desk:
      {{#rows}}
    - {{id}}
      {{/rows}}
    {{! a note
    over two lines }}
    end
    """
    #expect(try await render(source, ["rows": [["id": 1], ["id": 2]]]) == "Desk:\n- 1\n- 2\nend")
    #expect(try await render("a {{#x}}b{{/x}} c\n", ["x": true]) == "a b c\n")
  }

  @Test func aStandalonePartialIsIndentedLikeItsLine() async throws {
    let rendered = try await render("list:\n  {{> /item.md}}\nend", ["name": "n"], partials: ["/item.md": "one {{name}}\ntwo\n"])
    #expect(rendered == "list:\n  one n\n  two\nend")
    #expect(try await render("[{{>/item.md}}]", partials: ["/item.md": "x"]) == "[x]")
  }

  @Test func aFailedNameRendersItsLineInPlace() async throws {
    let source = "a\n{{#desk}}\n- {{title}}\n{{/desk}}\nb {{desk}}"
    #expect(try await render(source, failures: ["desk": "(query failed)"]) == "a\n(query failed)\nb (query failed)")
  }

  @Test func aFailureShadowsOuterBindingsAndAnInnerBindingShadowsOuterFailures() async throws {
    let template = try Mustache("{{#desk}}{{.}}{{/desk}}")
    let outer = Mustache.Scope(["desk": ["outer"]])
    let failed = outer.adding([:], failures: ["desk": "(query failed)"])
    #expect(await template.render(failed) { _, _ in "" } == "(query failed)\n")
    let rebound = failed.adding(["desk": ["inner"]], failures: [:])
    #expect(await template.render(rebound) { _, _ in "" } == "inner")
  }

  @Test func setDelimitersShowTagsLiterally() async throws {
    let source = "{{=<% %>=}}\nWrite `{{#x}}…{{/x}}` and `{{> /p}}`: <%name%>.\n<%={{ }}=%>\n{{name}}"
    #expect(try await render(source, ["name": "n", "x": true]) == "Write `{{#x}}…{{/x}}` and `{{> /p}}`: n.\nn")
  }

  @Test func malformedTemplatesAreSyntaxErrors() {
    #expect(throws: Mustache.SyntaxError(message: "{{#a}} is never closed")) { try Mustache("{{#a}}") }
    #expect(throws: Mustache.SyntaxError(message: "{{/b}} closes {{#a}}")) { try Mustache("{{#a}}{{/b}}") }
    #expect(throws: Mustache.SyntaxError(message: "{{/a}} closes no section")) { try Mustache("{{/a}}") }
    #expect(throws: Mustache.SyntaxError(message: "a tag opened with {{ is never closed")) { try Mustache("{{a") }
    #expect(throws: Mustache.SyntaxError(message: "a set-delimiter tag names two delimiters without =")) { try Mustache("{{=<%=}}") }
    #expect(throws: Mustache.SyntaxError(message: "a tag opened with <% is never closed")) { try Mustache("{{=<% %>=}}<%a") }
    #expect(throws: Mustache.SyntaxError(message: "a tag names nothing")) { try Mustache("{{ }}") }
  }
}
