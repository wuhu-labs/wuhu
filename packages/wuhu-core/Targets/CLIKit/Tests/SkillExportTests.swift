#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Fetch
import Scratch
import Testing

@Suite
struct SkillExportTests {
  @Test func payloadsAreEmbeddedAndWellFormed() throws {
    let skills = try #require(SkillCatalog.embedded)
    #expect(skills.map(\.name) == ["wuhu", "wuhu-cli"])
    for skill in skills {
      #expect(skill.markdown.hasPrefix("---\nname: \(skill.name)\n"))
      #expect(skill.markdown.contains("description:"))
      #expect(skill.markdown.count > 1000)
      #expect(!skill.markdown.contains(SkillCatalog.marker))
    }
  }

  @Test func cliSkillCoversEveryParserVerb() throws {
    let skills = try #require(SkillCatalog.embedded)
    let cli = try #require(skills.first { $0.name == "wuhu-cli" })
    let verbs = Command.usage
      .split(separator: "\n")
      .filter { $0.hasPrefix("  ") }
      .compactMap { $0.split(separator: " ").first.map(String.init) }
    #expect(verbs.count > 20)
    for verb in verbs {
      #expect(cli.markdown.contains("wuhu \(verb)"), "wuhu-cli skill never shows `wuhu \(verb)`")
    }
  }

  @Test func skillsCoverTheSessionDomain() throws {
    let skills = try #require(SkillCatalog.embedded)
    let concept = try #require(skills.first { $0.name == "wuhu" })
    let cli = try #require(skills.first { $0.name == "wuhu-cli" })
    for anchor in ["send_message", "/models.json", "broadcast"] {
      #expect(concept.markdown.contains(anchor))
    }
    for anchor in ["--wait", "wuhu inbox", "wuhu models update", "--dev-import"] {
      #expect(cli.markdown.contains(anchor))
    }
  }

  @Test func exportWritesBothAgentHomesAndIsIdempotent() async throws {
    let harness = try ExportHarness()
    #expect(await harness.run() == 0)
    let skills = try #require(SkillCatalog.embedded)
    var expected = ""
    for destination in [".claude/skills", ".agents/skills"] {
      for skill in skills {
        let file = harness.home
          .appendingPathComponent(destination, isDirectory: true)
          .appendingPathComponent(skill.name, isDirectory: true)
          .appendingPathComponent("SKILL.md")
        expected += "wrote \(file.path)\n"
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written == skill.markdown + "\n" + SkillCatalog.marker)
      }
    }
    #expect(await harness.stdout.text == expected)

    let again = try ExportHarness(home: harness.home)
    #expect(await again.run() == 0)
    let secondReport = await again.stdout.text
    #expect(secondReport == expected.replacingOccurrences(of: "wrote ", with: "unchanged "))
  }

  @Test func exportUpdatesItsOwnFilesAndRefusesForeignOnes() async throws {
    let harness = try ExportHarness()
    let claude = harness.home.appendingPathComponent(".claude/skills/wuhu", isDirectory: true)
    let agents = harness.home.appendingPathComponent(".agents/skills/wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let stale = "old content\n" + SkillCatalog.marker
    let foreign = "the user's own wuhu skill\n"
    try stale.write(to: claude.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try foreign.write(to: agents.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    #expect(await harness.run() == 0)
    let report = await harness.stdout.text
    #expect(report.contains("updated \(claude.appendingPathComponent("SKILL.md").path)\n"))
    #expect(report.contains("skipped \(agents.appendingPathComponent("SKILL.md").path) (not installed by wuhu skill export; remove it to reinstall)\n"))
    let kept = try String(contentsOf: agents.appendingPathComponent("SKILL.md"), encoding: .utf8)
    #expect(kept == foreign)
    let updated = try String(contentsOf: claude.appendingPathComponent("SKILL.md"), encoding: .utf8)
    #expect(updated.hasPrefix("---\nname: wuhu\n"))
  }

  @Test func exportWithoutHomeFails() async throws {
    let harness = try ExportHarness(environment: [:])
    #expect(await harness.run() == 1)
    #expect(await harness.stderr.text == "HOME is not set\n")
  }
}

private struct ExportHarness {
  let scratch: ScratchFolder
  let home: URL
  let runner: CommandRunner
  let stdout: Sink
  let stderr: Sink

  init(home: URL? = nil, environment: [String: String]? = nil) throws {
    self.scratch = try ScratchFolder("skill-export")
    let root = self.scratch.url
    self.home = home ?? root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
    let stdout = Sink()
    let stderr = Sink()
    self.stdout = stdout
    self.stderr = stderr
    self.runner = CommandRunner(
      fetch: FetchClient { _ in Response(status: .notFound) },
      stdin: { "" },
      stdout: { text in await stdout.append(text) },
      stderr: { text in await stderr.append(text) },
      environment: environment ?? ["HOME": self.home.path],
      currentDirectory: root.path,
    )
  }

  func run() async -> Int32 {
    await self.runner.run(arguments: ["skill", "export"])
  }
}

private actor Sink {
  var text = ""

  func append(_ value: String) {
    self.text += value
  }
}
