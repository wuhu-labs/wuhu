import DeterministicDependencies
import JSONValue
import LoopCore
import SpaceContract
import SpaceCore
import SpaceTools
import Testing

@Suite(.deterministicDependencies) struct TablePermissionTests {
  @Test func aReadableGroupDoesNotPermitTableWrites() async throws {
    try await withSessionContext { base in
      let account = try await base.space.addAccount(kind: .human, name: "Morgan")
      let group = try await base.space.createGroup(alias: "reader", owner: account.id)
      let owner = try await base.space.createGroup(alias: "owner_group", owner: account.id)
      for id in [group, owner] {
        try await base.space.setVisibility(.private, of: id, by: (try await base.space.ensureDevPerson()).actor, acting: id)
      }
      try await base.space.setGrant(.group, group.rawValue, role: .read, in: owner, by: (try await base.space.ensureDevPerson()).actor, acting: owner)
      let session = try await base.space.sessions.createSession(
        group: group, title: "reader", kind: .agent, createdBy: "reader",
        model: .init(provider: "test", model: "test", effort: "high"),
      )
      let reader = SpaceToolContext(space: base.space, principal: try await base.space.principal(of: session))
      let path = "wuhu://\(owner.rawValue).localspace/.agents/skills/test/data.table"
      let header: JSONValue = ["columns": [["name": "title", "type": "string"]]]
      let create = await failure("table.create", ["path": .string(path), "header": header], reader)
      #expect(create?.payload.object?["code"] == "unauthorized")
      let ownerSeat = SpaceToolContext(space: base.space, principal: Principal(actor: .person(persona: "Morgan", account: account.id), group: owner))
      _ = try await run("table.create", ["path": .string(path), "header": header], ownerSeat)
      let mutate = await failure("table.mutate", ["path": .string(path), "ops": [["kind": "insert", "values": ["injected"]]]], reader)
      #expect(mutate?.payload.object?["code"] == "unauthorized")
    }
  }
}
