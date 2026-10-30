import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import GRDB
import InMemoryTracing
import ServerTelemetry
@testable import SpaceCore
import Synchronization
import Testing
import Tracing

private let shebang = "#!/usr/bin/env -S wuhu script\n"

private let completionSSE = #"""
event: message_start
data: {"message":{"model":"test-model","usage":{"input_tokens":3}}}

event: content_block_start
data: {"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"delta":{"type":"text_delta","text":"ok"}}

event: content_block_stop
data: {"index":0}

event: message_delta
data: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

event: message_stop
data: {}

"""#

private func hex(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Suite(.deterministicDependencies) struct ScriptCLITests {
  private func script(_ h: IdentityHarness, _ source: String) throws -> String {
    let file = h.cwd.appendingPathComponent("run.js")
    try Data(source.utf8).write(to: file)
    return file.lastPathComponent
  }

  @Test func aShebangFilePrintsItsResultThenItsUpdatesAndItsSpanRecordsTheSourceHash() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let source = shebang + """
      result("args " + import.meta.args.length)
      update("one " + import.meta.args[0])
      update("two")
      """
      let file = try script(h, source)
      let tracer = InMemoryTracer()
      let run = await withDependencies { $0.tracer = tracer } operation: { await h.asSession(["script", file, "a", "--b"]) }
      #expect(run.code == 0, "\(run.stderr)")
      #expect(run.stdout == "args 2\none a\ntwo\n")
      let scripts = tracer.finishedSpans.filter { $0.operationName == "script.run" }
      #expect(scripts.map { $0.attributes.get("wuhu.script.kind") } == [.string("wuhu_script")])
      #expect(scripts.map { $0.attributes.get("wuhu.script.source.sha256") } == [.string(hex(source))])
      #expect(scripts.map { $0.attributes.get("wuhu.updates") } == [.int64(2)])
      #expect(scripts.map { $0.attributes.get("wuhu.outcome") } == [.string("released")])
      #expect(scripts.allSatisfy { $0.parentSpanID == nil && $0.attributes.get("wuhu.group.id") != nil })
    }
  }

  @Test func aScriptThatFailsOrNeverAnswersExitsNonzeroWithTheReason() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let threw = await h.asSession(["script", try script(h, "console.log(\"before\")\nthrow new Error(\"boom\")\n")])
      #expect(threw.code == 1)
      #expect(threw.stdout.isEmpty)
      #expect(threw.stderr.contains("threw before calling result(): Error: boom"), "\(threw.stderr)")

      let silent = await h.asSession(["script", try script(h, "console.log(\"quiet\")\n")])
      #expect(silent.code == 1)
      #expect(silent.stderr.contains("finished without calling result()"), "\(silent.stderr)")
      #expect(silent.stderr.contains("quiet"), "the console tail comes with the reason")

      let after = await h.asSession(["script", try script(h, "result(\"ok\")\nupdate(\"then\")\nthrow new Error(\"late\")\n")])
      #expect(after.code == 1)
      #expect(after.stdout == "ok\nthen\n")
      #expect(after.stderr.contains("failed after its result: Error: late"), "\(after.stderr)")
    }
  }

  @Test func aStreamThatStopsBeforeTheRunEndsExitsNonzero() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let file = try script(h, "result(\"half\")\n")
      let cut = FetchClient { request in
        guard request.url.path == "/v1/scripts" else { return try await h.fetch(request) }
        return Response(status: .ok, body: .chunk(Data(#"data: {"kind":"result","text":"half"}\#n\#n"#.utf8), contentType: "text/event-stream"))
      }
      let run = await h.run(["script", file], environment: h.sessionEnvironment, fetch: cut)
      #expect(run.code == 1)
      #expect(run.stdout == "half\n")
      #expect(run.stderr.contains("script: the server closed the stream before the run ended"), "\(run.stderr)")
    }
  }

  @Test func aTerminalRunActsAsThePersonAndItsInferenceNamesTheirOwnGroup() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness(dev: false)
      let (terminal, account) = try await h.signIn("alice")
      let file = try script(h, shebang + """
      import { complete } from 'wuhu:ai'
      import { createSession } from 'wuhu:session'
      const said = await complete('hello', { model: 'testing/test-model' })
      await createSession({ title: 'helper', provider: 'testing', model: 'test-model' })
      result(said + " " + import.meta.args[0])
      update("session " + import.meta.session)
      """)
      let provider = FetchClient { request in
        #expect(request.url.absoluteString == "http://localhost:1/v1/messages")
        return Response(status: .ok, body: .bytes(Data(completionSSE.utf8), contentType: "text/event-stream"))
      }
      let run = await withDependencies { $0.fetch = provider } operation: { await h.run(["script", file, "x"], environment: terminal) }
      #expect(run.code == 0, "\(run.stderr)")
      #expect(run.stdout == "ok x\nsession null\n")
      let personal = try #require(try await h.space.personalGroup(of: account.id))
      let inferences = try await h.space.query(
        #"SELECT grp, session, outcome, firing LIKE 'terminal-%' FROM "wuhu://*.localspace/inferences""#,
        as: Principal(actor: .person(persona: "alice", account: account.id), group: personal),
      ).rows
      #expect(inferences == [[.text(personal.rawValue), .null, .text("ok"), .integer(1)]], "\(inferences)")
      let helper = try await h.space.query("SELECT kind, parent, created_by FROM sessions WHERE title = 'helper'", as: .shared(.anonymous)).rows
      #expect(helper.map { Array($0.prefix(2)) } == [[.text("agent"), .null]], "\(helper)")
      guard case let .text(creator)? = helper.first?.last else { Issue.record("helper has no creator: \(helper)"); return }
      #expect(try await h.space.persona(named: creator)?.account == account.id)

      let elsewhere = try script(h, """
      import { createSession } from 'wuhu:session'
      await createSession({ title: 'mine', provider: 'testing', model: 'test-model' })
      result('made')
      """)
      let placed = await h.run(["--group", personal.rawValue, "script", elsewhere], environment: terminal)
      #expect(placed.code == 0, "\(placed.stderr)")
      let mine = try await h.space.query(
        #"SELECT title FROM "wuhu://\#(personal.rawValue).localspace/sessions""#, as: Principal(actor: .person(persona: "alice", account: account.id), group: personal),
      ).rows
      #expect(mine == [[.text("mine")]], "\(mine)")

      let threw = await h.run(["script", try script(h, "throw new Error(\"boom\")\n")], environment: terminal)
      #expect(threw.code == 1)
      #expect(threw.stdout.isEmpty)
      #expect(threw.stderr.contains("threw before calling result(): Error: boom"), "\(threw.stderr)")
    }
  }

  // A persona older than personal groups has none until its first terminal
  // run, which makes it.
  @Test func aTerminalRunMakesTheMissingPersonalGroupOfAnOlderPersona() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness(dev: false)
      let (terminal, account) = try await h.signIn("bob")
      let first = await h.run(["script", try script(h, "result(1)\n")], environment: terminal)
      #expect(first.code == 0, "\(first.stderr)")
      let personal = try #require(try await h.space.personalGroup(of: account.id))
      try await h.space.writer.write { db in
        try db.execute(sql: "DELETE FROM group_roles WHERE grp = ?", arguments: [personal.rawValue])
        try db.execute(sql: "DELETE FROM groups WHERE id = ?", arguments: [personal.rawValue])
      }
      #expect(try await h.space.personalGroup(of: account.id) == nil)

      let run = await h.run(["script", try script(h, "result(2)\n")], environment: terminal)
      #expect(run.code == 0, "\(run.stderr)")
      #expect(run.stdout == "2\n")
      #expect(try await h.space.personalGroup(of: account.id) != nil)
    }
  }

  @Test func aSignedInAccountThatIsNoPersonIsRefused() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness(dev: false)
      let (terminal, account) = try await h.signIn("box", kind: .machine)
      // A group it owns lets it through the acting-group gate to the route.
      let own = try await h.space.ensurePersonalGroup(account: account.id)
      let refused = await h.run(["--group", own.rawValue, "script", try script(h, "result(1)\n")], environment: terminal)
      #expect(refused.code == 1)
      #expect(refused.stderr.contains("a terminal script runs as a signed-in person"), "\(refused.stderr)")
    }
  }

  @Test func aTerminalWithoutASignedInPersonIsRefusedByTheServer() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      try JSONEncoder().encode(["space": "space.test:5530"]).write(to: h.wallet.appendingPathComponent("config.json"), options: .atomic)
      let refused = await h.run(["script", try script(h, "result(1)\n")], environment: ["HOME": h.home.path])
      #expect(refused.code == 1)
      #expect(refused.stderr.contains("a terminal script runs as a signed-in person"), "\(refused.stderr)")
    }
  }
}
