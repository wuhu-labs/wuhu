import DocIndex
import Foundation
import SpaceFS
import Testing

private let path = try! SpacePath(validating: "/templates/t.md")
private let utc = TimeZone(secondsFromGMT: 0)!
private let afternoon = Date(timeIntervalSince1970: 1_793_718_240)

struct DocumentTemplateTests {
  @Test func `an incr template counts past the largest number among the folder's files`() throws {
    let template = try #require(DocumentTemplate(markdown: "---\ntemplate:\n  strategy: incr\n  prefix: ISSUE\n  pad: 4\nkind: issue\n---\n# New\n", at: path))
    #expect(template.naming == .incr(prefix: "ISSUE", pad: 4))
    #expect(template.instance == "---\nkind: issue\n---\n# New\n")
    #expect(template.name(among: [], at: afternoon, in: utc) == "ISSUE-0001.md")
    #expect(template.name(among: ["ISSUE-0009.md", "ISSUE-12345.md", "ISSUE-x.md", "TASK-99999.md", "ISSUE-99999.txt"], at: afternoon, in: utc) == "ISSUE-12346.md")
  }

  @Test func `a date template names the day, in folders and to the minute when asked`() throws {
    let day = try #require(DocumentTemplate(markdown: "---\ntemplate: {strategy: date}\n---\n# Journal\n", at: path))
    #expect(day.instance == "# Journal\n")
    #expect(day.name(among: [], at: afternoon, in: utc) == "2026-11-03.md")
    let minute = try #require(DocumentTemplate(markdown: "---\ntemplate:\n  strategy: date\n  folders: true\n  specificity: minute\n---\n", at: path))
    #expect(minute.name(among: [], at: afternoon, in: utc) == "2026/11/03-15-04.md")
    #expect(minute.name(among: [], at: afternoon, in: TimeZone(secondsFromGMT: 9 * 3600)!) == "2026/11/04-00-04.md")
  }

  @Test func `a file without a known strategy is no template`() {
    for text in ["# plain", "---\nkind: note\n---\n", "---\ntemplate: incr\n---\n", "---\ntemplate: {strategy: incr, prefix: issue}\n---\n", "---\ntemplate: {strategy: weekly}\n---\n"] {
      #expect(DocumentTemplate(markdown: text, at: path) == nil)
    }
  }
}
