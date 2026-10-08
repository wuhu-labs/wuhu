import Foundation
import JSONValue
@testable import SessionTools
import SpaceContract
import SpaceCore
import SpaceTools
import Testing

@Suite struct ScriptTemplateTests {
  @Test func atomicAllocationAndStrategyValidation() async throws {
    try await withRig { rig in
      try await rig.write("/templates/task.md", "---\ntitle: Task\ntemplate: {strategy: incr, prefix: TASK, pad: 3}\n---\nbody\n")
      try await rig.write("/templates/day.md", "---\ntemplate: {strategy: date, folders: true, specificity: minute}\n---\njournal\n")
      try await rig.write("/templates/bad.md", "---\ntemplate: {strategy: guessed}\n---\n")
      let result = try await rig.evaluate(#"""
      import {instantiateTemplate} from "wuhu:space"
      const paths = await Promise.all(Array.from({length:20},()=>instantiateTemplate("/templates/task.md",{in:"/tasks"})))
      const day = await instantiateTemplate("/templates/day.md",{in:"/journal"})
      const codes = []
      for (const call of [()=>instantiateTemplate("/templates/bad.md"),()=>instantiateTemplate("/missing.md"),()=>instantiateTemplate("/templates/task.md",{force:true}),()=>instantiateTemplate("/templates/task.md",null)]) {
        try { await call(); codes.push("ok") } catch(e) { codes.push(e.code) }
      }
      result({paths:paths.map(p=>p.path).sort(),day:day.path,codes})
      """#)
      #expect(result.object?["paths"]?.array == (1 ... 20).map { .string(String(format: "/tasks/TASK-%03d.md", $0)) })
      #expect(result.object?["day"]?.stringValue?.hasPrefix("/journal/") == true)
      #expect(result.object?["codes"] == ["invalidArgument", "notFound", "invalidArgument", "invalidArgument"])
      let data = try await rig.space.fs(.shared).read("/tasks/TASK-001.md").1
      #expect(String(decoding: data, as: UTF8.self) == "---\ntitle: Task\n---\nbody\n")
    }
  }

  @Test func defaultAndExplicitDestinationsEnforceHomesAndLayers() async throws {
    try await withRig(group: GroupID(rawValue: "alice"), task: true) { rig in
      let principal = try await rig.space.principal(of: rig.session)
      let group = principal.group
      let context = SpaceToolContext(space: rig.space, principal: principal)
      let text = "---\ntemplate: {strategy: incr, prefix: NOTE}\n---\nbody\n"
      for (destination, owner) in [("/templates/a.md", group), ("/_/sessions/stranger/t.md", group), ("/.agents/skills/x/t.md", .shared), ("/templates/shared.md", .shared)] {
        _ = try await rig.space.fs(owner).write(destination, Data(text.utf8), ifMatch: nil)
      }
      let cases: [(String, String?, String)] = [
        ("/templates/a.md", nil, "ok"),
        ("/templates/a.md", "/_/sessions/\(rig.session.rawValue)", "ok"),
        ("/templates/a.md", "/_/sessions/stranger", "unauthorized"),
        ("/_/sessions/stranger/t.md", nil, "unauthorized"),
        ("/_/sessions/stranger/t.md", "/allowed", "ok"),
        ("wuhu://shared.localspace/.agents/skills/x/t.md", nil, "unauthorized"),
        ("wuhu://shared.localspace/templates/shared.md", "/.agents/skills/x", "ok"),
        ("/templates/a.md", "wuhu://shared.localspace/.agents/skills/x", "unauthorized"),
        ("wuhu://missing.localspace/t.md", nil, "notFound"),
        ("/templates/a.md", "wuhu://missing.localspace/target", "notFound"),
      ]
      for (template, destination, expected) in cases {
        let input: JSONValue = destination.map { ["template": .string(template), "in": .string($0)] } ?? ["template": .string(template)]
        let http: String
        do {
          _ = try await SpaceToolbox.all.first { $0.name == "new" }!.run(context, input: input)
          http = "ok"
        } catch { http = Wire.failure(error).payload.object?["code"]?.stringValue ?? "invalidArgument" }
        let options: JSONValue = destination.map { ["in": .string($0)] } ?? [:]
        let code = try await rig.evaluate("""
        import {instantiateTemplate} from 'wuhu:space'
        try { await instantiateTemplate(\(JSONValue.string(template).jsonString()), \(options.jsonString())); result('ok') }
        catch(e) {result(e.code)}
        """)
        #expect(http == expected, "HTTP \(template) -> \(String(describing: destination))")
        #expect(code == .string(expected), "module \(template) -> \(String(describing: destination))")
      }
    }
  }
}
