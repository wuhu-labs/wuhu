import DeterministicDependencies
import JSONValue
import SpaceContract
@testable import SpaceCore
import SpaceTools
import Testing

@Suite(.deterministicDependencies) struct TablePermissionTests {
  @Test func readableSharedDoesNotPermitProtectedTableWrites() async throws {
    let base = try makeContext()
    let group = GroupID(rawValue: "reader")
    try await base.space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('reader', '2026-01-01T00:00:00Z')")
    }
    try await base.space.addReadEdge(from: group, to: .shared)
    let session = try await base.space.sessions.createSession(
      group: group, title: "reader", kind: .agent, createdBy: "reader",
      model: .init(provider: "test", model: "test", effort: "high"),
    )
    let reader = SpaceToolContext(space: base.space, principal: try await base.space.principal(of: session))
    let path = "wuhu://shared.localspace/.agents/skills/test/data.table"
    let header: JSONValue = ["columns": [["name": "title", "type": "string"]]]
    let create = await failure("table.create", ["path": .string(path), "header": header], reader)
    #expect(create?.payload.object?["code"] == "unauthorized")
    _ = try? await run("table.create", ["path": .string(path), "header": header], base)
    let mutate = await failure("table.mutate", ["path": .string(path), "ops": [["kind": "insert", "values": ["injected"]]]], reader)
    #expect(mutate?.payload.object?["code"] == "unauthorized")
  }
}
