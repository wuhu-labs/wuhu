import Foundation
import SpaceCore
import SpaceFS
@testable import SystemFiles
import Testing

@Suite struct SystemFilesTests {
  @Test func theBinaryCarriesTheSystemInstructionsAndSkills() {
    #expect(SystemFiles.files["/AGENTS.md"] != nil)
    #expect(SystemFiles.instructions.skills.map(\.name) == [
      "ai-scripts", "avatar", "data-organization", "data-views", "devices", "machine-scripts", "monitor", "observe-group-channel", "read-box", "script-runtime", "secret-scripts", "sessions", "sidebars", "space-html-pages", "space-scripts", "web-search", "widgets", "writing-style",
    ])
    #expect(SystemFiles.instructions.skills.allSatisfy { !$0.description.isEmpty })
    #expect(SystemFiles.instructions.skills.first?.path == "wuhu://system/skills/ai-scripts/SKILL.md")
    #expect(SystemFiles.instructions.sections.map(\.path) == ["wuhu://system/AGENTS.md"])
    #expect(SystemFiles.instructions.sections.first?.text.hasPrefix("# Working in a Wuhu space") == true)
    #expect(SystemFiles.session.sections.map(\.path) == ["wuhu://system/SESSION.md"])
  }

  @Test func theSystemAgentsTeachesNoRetiredVerbs() throws {
    let text = String(decoding: try #require(SystemFiles.files["/AGENTS.md"]), as: UTF8.self)
    #expect(!text.contains("mount"))
    #expect(!text.replacing("side channel", with: "").lowercased().contains("channel"), "channels are conversations now")
    #expect(!text.contains("## Sessions, conversations, messaging"))
  }

  @Test func everyModuleExportHasExactlyOneDocumentingSkill() throws {
    let inventory = try JSONDecoder().decode([String: [String]].self, from: #require(SystemFiles.files["/module-exports.json"]))
    var documented: [String: [String: [String]]] = [:]
    for skill in SystemFiles.instructions.skills {
      let text = String(decoding: try #require(SystemFiles.files["/skills/\(skill.name)/SKILL.md"]), as: UTF8.self)
      let parts = text.components(separatedBy: "\n---\n")
      let body = try #require(parts.last)
      for line in try #require(parts.first).components(separatedBy: "\n") where line.hasPrefix("script_exports: ") {
        let declaration = Data(line.dropFirst("script_exports: ".count).utf8)
        for (module, exports) in try JSONDecoder().decode([String: [String]].self, from: declaration) {
          for name in exports {
            #expect(body.contains(name), "\(skill.name) declares but does not document \(module).\(name)")
            documented[module, default: [:]][name, default: []].append(skill.name)
          }
        }
      }
    }
    #expect(Set(documented.keys) == Set(inventory.keys))
    for (module, exports) in inventory {
      let owners = documented[module, default: [:]]
      #expect(Set(owners.keys) == Set(exports), "\(module) documentation differs from inventory")
      for name in exports {
        #expect(owners[name]?.count == 1, "\(module).\(name) must have one skill owner: \(owners[name] ?? [])")
      }
    }
  }

  @Test func theManualAndSkillsKeepTheirAnchors() throws {
    func text(_ path: String) throws -> String {
      String(decoding: try #require(SystemFiles.files[path], "missing \(path)"), as: UTF8.self)
    }
    let anchors: [String: [String]] = [
      "/AGENTS.md": [
        "/models.json", "notifications", "/_/shell.js", "/_/sessions/<your-id>/",
        "wuhu://system/", "## Replies", "`writing-style` skill", "## Scratch files",
      ],
      "/skills/writing-style/SKILL.md": ["first line", "15 lines", "## A proposal", "no closing offer"],
      "/skills/avatar/SKILL.md": ["which number?", "cropped, not regenerated", "wuhu:machine"],
      "/skills/data-organization/SKILL.md": ["frontmatter", ".view", "/.widgets/", "Nothing is created until"],
      "/skills/space-html-pages/SKILL.md": [
        "/_/observe", "wuhu.context", "wuhu:navigate", "--wuhu-inset-top", "safe-area-inset-top",
        "viewport-fit=cover", "user-scalable=no", "overflow-x: clip", "overscroll-behavior-x: none",
        "touch-action: manipulation", "overflow-x: auto",
      ],
      "/skills/space-scripts/SKILL.md": [#""strategy":"incr""#, "allowDropColumns", "issuerFor", "createChannel"],
      "/skills/ai-scripts/SKILL.md": ["billed to your session", "wuhu://settings.localspace/models.json", "CapabilityError", "diarize"],
      "/skills/machine-scripts/SKILL.md": ["execStatus", "spawn", "Uint8Array"],
      "/skills/secret-scripts/SKILL.md": ["placeholder", "human admin"],
      "/skills/script-runtime/SKILL.md": ["fetchIdentityUnavailable", "256 files"],
      "/skills/sessions/SKILL.md": ["wuhu:session", "topLevel: true", "expectsReply: true", "Promise.all"],
      "/skills/observe-group-channel/SKILL.md": ["conversation_id", "handler", "state", "wake", "complete", "every-message", "topic", "name-mention"],
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
