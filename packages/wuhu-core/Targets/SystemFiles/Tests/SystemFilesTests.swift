import Foundation
import SpaceCore
import SpaceFS
@testable import SystemFiles
import Testing

@Suite struct SystemFilesTests {
  @Test func theBinaryCarriesTheSystemAgentsAndTenSkills() {
    #expect(SystemFiles.files["/AGENTS.md"] != nil)
    #expect(SystemFiles.instructions.skills.map(\.name) == [
      "avatar", "data-views", "image", "monitor", "read-box", "sessions", "space-html-pages", "transcription", "web-search", "widgets",
    ])
    #expect(SystemFiles.instructions.skills.allSatisfy { !$0.description.isEmpty })
    #expect(SystemFiles.instructions.skills.first?.path == "wuhu://system/skills/avatar/SKILL.md")
    #expect(SystemFiles.instructions.sections.map(\.path) == ["wuhu://system/AGENTS.md"])
    #expect(SystemFiles.rendered.hasPrefix("from wuhu://system/AGENTS.md:\n\n# Working in a Wuhu space"))
    #expect(SystemFiles.rendered.contains("- monitor — "))
  }

  @Test func theSystemAgentsTeachesNoRetiredVerbs() throws {
    let text = String(decoding: try #require(SystemFiles.files["/AGENTS.md"]), as: UTF8.self)
    #expect(!text.contains("mount"))
    #expect(!text.replacing("side channel", with: "").lowercased().contains("channel"), "channels are conversations now")
    #expect(!text.contains("## Sessions, conversations, messaging"))
  }

  @Test func theManualAndSkillsKeepTheirAnchors() throws {
    func text(_ path: String) throws -> String {
      String(decoding: try #require(SystemFiles.files[path], "missing \(path)"), as: UTF8.self)
    }
    let anchors: [String: [String]] = [
      "/AGENTS.md": [
        "/_/observe", "/models.json", #""strategy":"incr""#, "notifications", "/_/shell.js", "/_/sessions/<your-id>/",
        "wuhu://system/",
      ],
      "/skills/space-html-pages/SKILL.md": ["wuhu.context", "wuhu:navigate", "--wuhu-inset-top", "safe-area-inset-top"],
      "/skills/sessions/SKILL.md": ["wuhu:session", "topLevel: true", "expectsReply: true", "Promise.all"],
    ]
    for (path, expected) in anchors {
      let body = try text(path)
      for anchor in expected { #expect(body.contains(anchor), "\(path) lost \(anchor)") }
    }
    for skill in SystemFiles.instructions.skills {
      let body = try text("/skills/\(skill.name)/SKILL.md")
      #expect(body.hasPrefix("---\nname: \(skill.name)\ndescription: "), "\(skill.name) frontmatter")
    }
  }

  @Test func readsListsAndStatsLikeAFolder() async throws {
    let fs = SystemVFS(files: ["/AGENTS.md": Data("a\nb".utf8), "/skills/x/SKILL.md": Data("# X".utf8), "/skills/x/lib.js": Data()])
    #expect(try await fs.read("/AGENTS.md").1 == Data("a\nb".utf8))
    #expect(try await fs.list("/").1.map(\.name) == ["AGENTS.md", "skills"])
    #expect(try await fs.list("/skills/x").1.map(\.name) == ["SKILL.md", "lib.js"])
    #expect(try await fs.stat("/skills").kind == .directory)
    #expect(try await fs.stat("/AGENTS.md").lineCount == 2)
    await #expect(throws: SpaceError.notFound("wuhu://system/nope")) { _ = try await fs.read("/nope") }
    await #expect(throws: SpaceError.notAFile("wuhu://system/skills")) { _ = try await fs.read("/skills") }
    await #expect(throws: SpaceError.notADirectory("wuhu://system/AGENTS.md")) { _ = try await fs.list("/AGENTS.md") }
  }

  @Test func refusesEveryMutation() async throws {
    let fs = SystemFiles.vfs
    await #expect(throws: SpaceError.systemReadOnly("wuhu://system/AGENTS.md")) {
      _ = try await fs.write("/AGENTS.md", Data(), ifMatch: nil)
    }
    await #expect(throws: SpaceError.systemReadOnly("wuhu://system/AGENTS.md")) {
      try await fs.delete("/AGENTS.md", ifMatch: nil)
    }
    await #expect(throws: SpaceError.systemReadOnly("wuhu://system/AGENTS.md")) {
      try await fs.move("/AGENTS.md", to: "/b.md")
    }
  }
}
