import JSONValue
import SpaceContract
import SpaceCore
import SpaceTools
import Testing

@Suite struct TablePermissionTests {
  @Test func readableSharedDoesNotPermitProtectedTableWrites() async throws {
    let base = try makeContext()
    let account = try await base.space.addAccount(kind: .human, name: "reader")
    let group = try await base.space.ensurePersonalGroup(account: account.id)
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
