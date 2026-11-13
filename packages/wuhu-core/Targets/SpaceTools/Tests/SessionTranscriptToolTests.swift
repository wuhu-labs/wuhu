import DeterministicDependencies
import JSONValue
import LoopCore
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceTools
import Testing

@Suite(.deterministicDependencies) struct SessionTranscriptToolTests {
  private func folder(_ context: SpaceToolContext) async throws -> String {
    let id = try await context.space.sessions.createSession(
      group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .init(provider: "test", model: "test", effort: "high"), snapshot: .init(),
    )
    return "/_/session-transcripts/\(id.rawValue)"
  }

  @Test func theToolsReadTheFiles() async throws {
    try await withSessionContext { context in
      let folder = try await folder(context)
      let listed = try await run("ls", .object(["path": .string(folder)]), context, as: ListOutput.self)
      #expect(listed.entries.map(\.name) == ["current.jsonl", "current.outline.txt", "0.jsonl", "0.outline.txt"])
      for path in [folder + "/current.outline.txt", "wuhu://shared.localspace" + folder + "/0.outline.txt"] {
        let read = try await run("read", .object(["path": .string(path)]), context, as: ReadOutput.self)
        #expect(read.content.hasPrefix("3 ") && read.content.contains(" user head "))
      }
      let grep = try await run("grep", .object(["pattern": "head", "path": .string(folder), "hidden": true]), context, as: GrepOutput.self)
      #expect(!grep.matches.isEmpty)
    }
  }

  @Test func theToolsRefuseWritesAndRevisions() async throws {
    try await withSessionContext { context in
      let folder = try await folder(context)
      let file = folder + "/current.jsonl"
      let attempts: [(String, JSONValue)] = [
        ("write", .object(["path": .string(file), "content": "x"])),
        ("write", .object(["path": .string(folder + "/new.md"), "content": "x"])),
        ("rm", .object(["path": .string(file)])),
        ("mv", .object(["from": .string(file), "to": "/stolen.jsonl"])),
        ("read", .object(["path": .string(file), "rev": 1])),
      ]
      for (tool, input) in attempts {
        let refused = await failure(tool, input, context)
        #expect(refused?.payload.object?["code"] == "unsupported", "\(tool) \(input)")
      }
    }
  }
}
