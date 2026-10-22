import DeterministicDependencies
import JSONValue
import SpaceContract
@testable import SpaceCore
import SpaceTools
import Testing

@Suite(.deterministicDependencies) struct TablePermissionTests {
  @Test func aReadableGroupDoesNotPermitTableWrites() async throws {
    let base = try makeContext()
    let group = GroupID(rawValue: "reader")
    let owner = GroupID(rawValue: "owner")
    try await base.space.writer.write { db in
      for id in ["reader", "owner"] {
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2026-01-01T00:00:00Z')", arguments: [id])
      }
    }
    // owner's list admits reader at read only.
    try await base.space.setGrant(.group, group.rawValue, role: .read, in: owner, by: .anonymous, acting: owner)
    let session = try await base.space.sessions.createSession(
      group: group, title: "reader", kind: .agent, createdBy: "reader",
      model: .init(provider: "test", model: "test", effort: "high"),
    )
    let reader = SpaceToolContext(space: base.space, principal: try await base.space.principal(of: session))
    let path = "wuhu://owner.localspace/.agents/skills/test/data.table"
    let header: JSONValue = ["columns": [["name": "title", "type": "string"]]]
    let create = await failure("table.create", ["path": .string(path), "header": header], reader)
    #expect(create?.payload.object?["code"] == "unauthorized")
    let ownerSeat = SpaceToolContext(space: base.space, principal: Principal(actor: .anonymous, group: owner))
    _ = try? await run("table.create", ["path": .string(path), "header": header], ownerSeat)
    let mutate = await failure("table.mutate", ["path": .string(path), "ops": [["kind": "insert", "values": ["injected"]]]], reader)
    #expect(mutate?.payload.object?["code"] == "unauthorized")
  }
}
