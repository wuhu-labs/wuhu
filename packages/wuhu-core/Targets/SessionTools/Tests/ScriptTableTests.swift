import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceContract
import SpaceCore
import SpaceFS
import SpaceTools
import Testing

@Suite struct ScriptTableTests {
  @Test(arguments: [false, true]) func permissionsMatchHTTP(task: Bool) async throws {
    try await permissionMatrix(group: GroupID(rawValue: "alice"), task: task)
    try await permissionMatrix(group: .shared, task: task)
  }

  @Test func childAgentPermissions() async throws {
    try await permissionMatrix(group: .shared, task: false, child: true)
    try await permissionMatrix(group: GroupID(rawValue: "alice"), task: false, child: true)
  }

  private func permissionMatrix(group: GroupID, task: Bool, child: Bool = false) async throws {
    try await withRig(group: group, task: task, childAgent: child) { rig in
      let principal = try await rig.space.principal(of: rig.session)
      let context = SpaceToolContext(space: rig.space, principal: principal)
      let header: JSONValue = ["columns": [["name": "title", "type": "string"]]]
      let paths: [(String, String)] = [
        ("/ordinary.table", "ok"),
        ("/.agents/skills/x/data.table", group == .shared && (task || child) ? "unauthorized" : "ok"),
        ("wuhu://shared.localspace/qualified-ordinary.table", "ok"),
        ("wuhu://shared.localspace/.agents/skills/x/shared.table", group == .shared && !task && !child ? "ok" : "unauthorized"),
        ("/_/sessions/\(rig.session.rawValue)/own.table", "ok"),
        ("/_/sessions/stranger/foreign.table", "unauthorized"),
        ("wuhu://missing.localspace/no.table", "notFound"),
      ]
      for (path, expected) in paths {
        let input: JSONValue = ["path": .string(path), "header": header]
        let script = """
        import { createTable } from "wuhu:space"
        try { await createTable(\(JSONValue.string(path).jsonString()), \(header.jsonString())); result("ok") }
        catch (e) { result(e.code) }
        """
        let http = await outcome("table.create", input, context)
        #expect(http == expected, "HTTP create \(path)")
        if http == "ok" {
          let targetGroup: GroupID = path.hasPrefix("wuhu://shared") ? .shared : group
          let plain = path.hasPrefix("wuhu://shared.localspace") ? String(path.dropFirst("wuhu://shared.localspace".count)) : path
          try await rig.space.fs(targetGroup).delete(plain, ifMatch: nil)
        }
        #expect(try await rig.evaluate(script) == .string(expected), "module create \(path)")
        if expected == "ok" {
          #expect(await outcome("table.mutate", ["path": .string(path), "ops": []], context) == "ok")
          let result = try await rig.evaluate("""
          import {mutateRows, alterTable, tableSchema} from 'wuhu:space'
          await mutateRows(\(JSONValue.string(path).jsonString()), [])
          const schema = await tableSchema(\(JSONValue.string(path).jsonString()))
          await alterTable(\(JSONValue.string(path).jsonString()), \(header.jsonString()), {ifMatch:schema.token})
          result('ok')
          """)
          #expect(result == "ok")
          let schema = try await SpaceToolbox.all.first { $0.name == "table.schema" }!.run(context, input: ["path": .string(path)])
          #expect(await outcome("table.alter", ["path": .string(path), "header": header, "ifMatch": schema.object?["token"] ?? .null], context) == "ok")
        }
        if expected != "ok" {
          let alterInput: JSONValue = ["path": .string(path), "header": header, "ifMatch": "1"]
          #expect(await outcome("table.alter", alterInput, context) == expected)
          #expect(await outcome("table.mutate", ["path": .string(path), "ops": []], context) == expected)
          let denial = try await rig.evaluate("""
          import { alterTable, mutateRows } from "wuhu:space"
          const codes = []
          for (const call of [() => alterTable(\(JSONValue.string(path).jsonString()), \(header.jsonString()), {ifMatch:"1"}), () => mutateRows(\(JSONValue.string(path).jsonString()), [])]) {
            try { await call(); codes.push("ok") } catch (e) { codes.push(e.code) }
          }
          result(codes)
          """)
          #expect(denial == .array([.string(expected), .string(expected)]))
        }
      }
    }
  }

  @Test func concurrentAltersCannotBothReplaceOneVersion() async throws {
    try await withRig { rig in
      let value = try await rig.evaluate(#"""
      import {createTable, alterTable, tableSchema} from 'wuhu:space'
      const header = {columns:[{name:'title',type:'string'}]}
      const created = await createTable('/race.table', header)
      const outcomes = await Promise.allSettled([1,2].map(n=>alterTable('/race.table',{columns:[...header.columns,{name:`c${n}`,type:'integer'}]},{ifMatch:created.token})))
      const current = await tableSchema('/race.table')
      result({success:outcomes.filter(x=>x.status==='fulfilled').length, conflicts:outcomes.filter(x=>x.status==='rejected' && x.reason.code==='conflict' && x.reason.token===current.token).length, columns:current.header.columns.length})
      """#)
      #expect(value == ["success": 1, "conflicts": 1, "columns": 2])
    }
  }

  @Test func tableLifecycleTokensValidationAndHistory() async throws {
    try await withRig { rig in
      let output = try await rig.evaluate(#"""
      import { createTable, tableSchema, alterTable, mutateRows, query, remove, move } from "wuhu:space"
      const header = {columns:[{name:"title",type:"string"}]}
      const created = await createTable("/reading.table", header)
      const codes = []
      const attempt = async (call) => { try { await call(); codes.push("ok") } catch(e) { codes.push(e.code); if (e.code === "conflict" && !e.token) codes.push("missingToken") } }
      // An existing path conflict need not carry a token; stale guarded operations do.
      try { await createTable("/reading.table", header) } catch(e) { codes.push(e.code) }
      for (const columns of [[{name:"id",type:"string"}], [{name:"ID",type:"string"}], [{name:"",type:"string"}], [{name:"x",type:"string"},{name:"X",type:"number"}], [{name:"bad\u0000",type:"string"}], [{name:"x",type:"blob"}], Array.from({length:257},(_,i)=>({name:`c${i}`,type:"integer"}))]) {
        await attempt(() => createTable("/invalid.table", {columns}))
      }
      await attempt(() => createTable("/invalid.table", {...header,indexes:[]}))
      await attempt(() => createTable("/invalid.table", {columns:[{name:"x",type:"string",sql:"TEXT"}]}))
      await attempt(() => tableSchema("/reading.table", {force:true}))
      await attempt(() => alterTable("/reading.table", header, {ifMatch:created.token,force:true}))
      await attempt(() => remove("/reading.table", {force:true}))
      await mutateRows("/reading.table", [{insert:{title:"The Left Hand of Darkness"}}])
      const current = await tableSchema("/reading.table")
      await attempt(() => alterTable("/reading.table", header))
      await attempt(() => alterTable("/reading.table", header, {ifMatch:created.token}))
      const added = {columns:[...header.columns,{name:"read",type:"boolean"}]}
      const altered = await alterTable("/reading.table", added, {ifMatch:current.token})
      await attempt(() => alterTable("/reading.table", header, {ifMatch:altered.token}))
      await attempt(() => alterTable("/reading.table", {columns:[{name:"title",type:"number"},{name:"read",type:"boolean"}]}, {ifMatch:altered.token}))
      const dropped = await alterTable("/reading.table", header, {ifMatch:altered.token,allowDropColumns:true})
      const historic = await tableSchema("/reading.table", {rev:altered.rev})
      await attempt(() => remove("/reading.table", {ifMatch:created.token}))
      await move("/reading.table", "/moved.table")
      const moved = await tableSchema("/moved.table")
      const rows = await query('SELECT title FROM "/moved.table"')
      await remove("/moved.table", {ifMatch:moved.token})
      try { await tableSchema("/moved.table") } catch(e) { codes.push(e.code) }
      result({codes, historicColumns:historic.header.columns.length, rows:rows[0].title, restoreRev:created.rev, removedRev:dropped.rev})
      """#)
      #expect(output.object?["codes"] == .array(["conflict", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument", "conflict", "invalidArgument", "invalidArgument", "conflict", "notFound"]))
      #expect(output.object?["historicColumns"] == 2)
      #expect(output.object?["rows"] == "The Left Hand of Darkness")
      guard case let .integer(rev)? = output.object?["restoreRev"] else { throw Mismatch("missing restoreRev") }
      let context = SpaceToolContext(space: rig.space, principal: try await rig.space.principal(of: rig.session))
      _ = try await SpaceToolbox.all.first { $0.name == "checkout" }!.run(context, input: ["path": "/reading.table", "rev": .integer(rev)])
      let restored = try await rig.evaluate("import {tableSchema} from 'wuhu:space'; result((await tableSchema('/reading.table')).header.columns)")
      #expect(restored == [["name": "title", "type": "string"]])
      #expect(try await rig.space.history(try SpacePath(validating: "/reading.table"), in: .shared).count >= 5)
    }
  }
}

private func outcome(_ verb: String, _ input: JSONValue, _ context: SpaceToolContext) async -> String {
  do {
    _ = try await SpaceToolbox.all.first { $0.name == verb }!.run(context, input: input)
    return "ok"
  } catch { return error.payload.object?["code"]?.stringValue ?? "invalidArgument" }
}
