import JSONValue
@testable import SessionTools
import SpaceTools
import Testing

@Suite struct ScriptOwnExecTests {
  @Test func foreignIDsAreNotFoundWithoutMachineAccess() async throws {
    try await withRig { rig in
      let result = try await rig.evaluate("import {killExec} from 'wuhu:machine'; try {await killExec('bad');result('allowed')}catch(e){result(e.code)}")
      #expect(result == "notFound")
    }
  }

  @Test func ownAndForeignExecsUseTheSameGate() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      let machine = try #require(try await rig.space.machines().first)
      let foreign = try await rig.space.mintExec(machine: machine.id, caller: "stranger")
      let own = try await rig.space.mintExec(machine: machine.id, caller: rig.session.rawValue)
      let context = SpaceToolContext(space: rig.space, principal: try await rig.space.principal(of: rig.session))
      #expect(try await context.ownExecs().map(\.id) == [own.id])
      do { _ = try await context.ownExecStatus(foreign.id.rawValue); Issue.record("foreign exec status allowed") }
      catch { #expect(Wire.failure(error).payload.object?["code"] == "notFound") }
      let output = try await rig.evaluate("""
      import {execs,execStatus,killExec} from 'wuhu:machine'
      const codes=[]
      for (const id of [\(JSONValue.string(foreign.id.rawValue).jsonString()),'invalid']) {
        for (const call of [()=>execStatus(id),()=>killExec(id)]) {
          try {await call();codes.push('ok')} catch(e) {codes.push(e.code)}
        }
      }
      result({codes,own:(await execs()).map(x=>x.id),status:(await execStatus(\(JSONValue.string(own.id.rawValue).jsonString()))).state})
      """)
      #expect(output.object?["codes"] == ["notFound", "notFound", "notFound", "notFound"])
      #expect(output.object?["own"] == [.string(own.id.rawValue)])
      #expect(output.object?["status"] == ["kind": "live"])
      let killed = try await rig.evaluate("""
      import {execStatus,killExec} from 'wuhu:machine'
      await killExec(\(JSONValue.string(own.id.rawValue).jsonString()))
      result((await execStatus(\(JSONValue.string(own.id.rawValue).jsonString()))).state)
      """)
      #expect(killed == ["kind": "cancelled"])
      #expect(world.execs.kills.value.contains(own.id))
    }
  }
}
