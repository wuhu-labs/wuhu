import Clocks
import ControlledTime
import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecrets
import struct Credentials.SpaceSecretStores
import Dependencies
import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import MachineChannel
import struct MachineContract.MachineID
import class MainHub.Hub
import func MainHub.resolveScriptModule
import struct MainHub.ScriptError
import struct MainHub.ScriptRun
import struct MainHub.ToolProblem
import enum ModelProviders.ModelPlacementReason
import OrderedCollections
import Scratch
import SessionDomain
@testable import SessionTools
import struct SpaceContract.GroupID
import enum SpaceContract.ScriptOutput
@testable import SpaceCore
import struct SpaceFS.SpacePath
@testable import SpaceServer
import struct SpaceTools.MachineSeam
import StructuredQueries
import Testing
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall

// Each test runs one script from Fixtures/Scripts and compares its transcript —
// every tool result, every message the script sent, and the harness's own
// probes, in order — with the checked-in <name>.expected.
@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct ScriptTests {
  @Test func executionEndsWithAnUnclosedObservation() async throws {
    try await withRig { rig in
      let result = try await rig.evaluate(#"""
      import { observe } from 'wuhu:space'
      const iterator = observe('SELECT path FROM docs')[Symbol.asyncIterator]()
      const first = await iterator.next()
      result(first.done === false)
      """#)
      #expect(result == .bool(true))
      try await rig.released()
    }
  }

  @Test func sample() async throws {
    let watchQueries = Box(0)
    let space = {
      try tracedSpace { sql in
        if sql.contains("lifecycle != 'archived'") { watchQueries.withLock { $0 += 1 } }
      }
    }
    try await withRig(space: space, fetch: githubStub) { rig in
      let children = try await rig.children(of: rig.session, [
        ("Port QuickJS kit", "claude-opus-5-5"),
        ("Review the gater", "gpt-5.6-sol"),
        ("Flaky CI sweep", "claude-opus-5-5"),
        ("Old migration", "claude-opus-5-5"),
      ])
      for child in children.prefix(2) {
        try await rig.space.worker.call(SessionCell.ID(child.rawValue)) { cell in
          try cell.show(child, owed: .inference)
        }
      }
      try await rig.space.sessions.markErrored(children[2], message: "inference failed: overloaded")
      for (child, hours) in zip(children, [1.0, 2.0, 3.0, 30.0]) {
        try await rig.activity(child, hoursAgo: hours)
      }
      try await rig.run("sample", ["wait_seconds": 60])

      try await until("the watch list is read") { watchQueries.value > 0 }
      let quickjs = children[0]
      try await rig.space.worker.call(SessionCell.ID(quickjs.rawValue)) { cell in
        try cell.show(quickjs, owed: .noRun)
      }
      try await rig.time.wake("the watch's poll", after: 61.234)
      try await rig.messages(1)
      try await rig.space.sessions.markErrored(children[1], message: "killed: out of context")
      try await rig.time.wake("the watch's next poll", after: 61.234)
      try await rig.messages(3)
      try await rig.released()
      try rig.expect("sample")
    }
  }

  @Test func resultConversionCannotPostASecondResult() async throws {
    try await withRig { rig in
      let outputs = Box<[ScriptOutput]>([])
      let source = "result({ toJSON() { result('inner'); return 'outer' } })"
      try await rig.command(source) { output in
        outputs.withLock { $0.append(output) }
      }
      let results = outputs.value.compactMap { if case let .result(text) = $0 { text } else { nil } }
      #expect(results == ["inner"])
      let failures = outputs.value.compactMap { if case let .failure(text) = $0 { text } else { nil } }
      #expect(failures.count == 1)
      #expect(failures.first?.contains("result() can be called only once") == true)
      #expect(try await rig.evaluate(source) == .string("inner"))
      try await rig.released()
      let notices = try await rig.delivered()
      #expect(notices.count == 1)
      #expect(notices.first?.contains("result() can be called only once") == true)
    }
  }

  @Test func resultTwice() async throws {
    try await withRig { rig in
      try await rig.run("result-twice")
      try await rig.messages(1)
      try rig.expect("result-twice")
    }
  }

  @Test func updateBeforeResult() async throws {
    try await withRig { rig in
      try await rig.run("update-before-result")
      try rig.expect("update-before-result")
    }
  }

  @Test func noResult() async throws {
    try await withRig { rig in
      try await rig.run("no-result")
      try rig.expect("no-result")
    }
  }

  @Test func theSpaceModuleQueriesObservesWatchesAndWritesAsTheSession() async throws {
    try await withRig { rig in
      let tasks = try SpacePath(validating: "/tasks.table")
      let header = TableHeader(columns: [
        TableColumn(name: "title", type: .text), TableColumn(name: "meta", type: .json), TableColumn(name: "done", type: .boolean),
      ])
      _ = try await rig.space.createTable(tasks, header: header, in: .shared, acting: .shared)
      _ = try await rig.space.mutateRows(tasks, [.insert(["first", ["k": 1], true])], in: .shared, acting: .shared)
      try await rig.write("/notes/plan.md", "---\n# kept\nstatus: open # inline\ndraft: true\n---\nbody\n")
      try await rig.run("space-data")
      try await rig.released()
      let (_, plan) = try await rig.space.fs(.shared).read("/notes/plan.md")
      rig.probe(String(decoding: plan, as: UTF8.self))
      try rig.expect("space-data")
    }
  }

  @Test func oversizeQuery() async throws {
    try await withRig { rig in
      try await rig.run("oversize")
      try rig.expect("oversize")
    }
  }

  @Test func oneBudgetCoversEveryBuffer() async throws {
    // The standard 64 MB budget and 20 MB bodies, at a sixty-fourth of the size.
    var limits = ScriptLimits.standard; limits.bufferBytes = 1 << 20
    let body = FetchClient { _ in
      Response(status: .ok, body: .string(String(repeating: "x", count: 320 << 10)))
    }
    try await withRig(fetch: body, limits: limits) { rig in
      try await rig.run("budget")
      try await rig.released()
      try rig.expect("budget")
    }
  }

  @Test func stopScript() async throws {
    try await withRig { rig in
      try await rig.run("stop")
      rig.probe("running: \(rig.running())")
      try await rig.cancel("script.\(rig.scriptID)", as: makeSession(rig.space, name: "stranger"))
      try await rig.stop(rig.scriptID)
      try await rig.messages(1)
      try await rig.released()
      rig.probe("running: \(rig.running())")
      try await rig.cancel("script.\(rig.scriptID)")
      try await rig.cancel("script.ffffffff")
      try await rig.cancel(rig.scriptID)
      try rig.expect("stop")
    }
  }

  @Test func sessionModuleCancels() async throws {
    try await withRig { rig in
      _ = try await rig.payload(["message": "x", "in_seconds": 600], tool: "timer")
      try await rig.run("session-cancel")
      try await rig.released()
      rig.probe("armed: \(try await rig.space.sessions.armedSubscriptions(rig.session).map(\.slot.id.rawValue))")
      try rig.expect("session-cancel")
    }
  }

  @Test func stopScriptKillsAScriptThatIgnoresIt() async throws {
    try await withRig { rig in
      try await rig.run("stop-ignored")
      async let stop: Void = rig.stop(rig.scriptID)
      try await rig.time.wake("the stop grace", after: 5)
      try await stop
      try await rig.released()
      try await holds("nothing more is sent") { try await rig.delivered().isEmpty }
      try rig.expect("stop-ignored")
    }
  }

  @Test func theOldWaitNamesAreRefused() async throws {
    try await withRig { rig in
      let cases: [(String, JSONValue, String)] = [
        ("timeout_seconds", .number(30), "run_script: timeout_seconds is renamed to wait_seconds"),
        ("on_timeout", .string("kill"), "run_script: on_timeout is gone; past wait_seconds a script always runs on, and cancel stops it"),
      ]
      for (name, value, message) in cases {
        guard case let .failure(refused) = try await rig.payload(["source": "result('never')", name: value]) else {
          Issue.record("\(name) was accepted")
          continue
        }
        #expect(refused.message == message)
        #expect(refused.code == "invalidArgument")
      }
    }
  }

  @Test func pastTheWaitTheScriptRunsOn() async throws {
    try await withRig { rig in
      async let run: Void = rig.run("timeout", ["wait_seconds": 30])
      try await rig.time.asleep("the script's sleep", dueIn: 120)
      try await rig.time.wake("the call's wait", after: 30)
      try await run
      try await rig.time.wake("the script's sleep", after: 90)
      try await rig.messages(1)
      try await rig.released()
      try rig.expect("timeout-detach")
    }
  }

  @Test func timeoutSparesAScriptThatAnswered() async throws {
    try await withRig { rig in
      try await rig.run("busy-after-result", ["wait_seconds": 30])
      await rig.time.advance(by: 30)
      try await rig.released()
      try rig.expect("busy-after-result")
    }
  }

  @Test func importsModulesFromTheSpace() async throws {
    try await withRig { rig in
      try await rig.write("/skills/geometry/area.js", """
      import { unit } from "./lib/unit.js"
      export const area = (side) => `${side * side} ${unit}`
      export const meta = import.meta.session
      """)
      try await rig.write("/skills/geometry/lib/unit.js", """
      import { area } from "../area.js"
      export const unit = "m²"
      export const cyclic = () => typeof area
      """)
      try await rig.run("modules")
      try rig.expect("modules")
    }
  }

  @Test func importsAMachineModuleThroughTheMachineName() async throws {
    try await withRig { rig in
      let id = try await rig.space.addMachineV2(name: "studio").machine.id.rawValue
      try await rig.write("/_/machines/\(id)/.agents/skills/hello/hello.js", """
      import { name } from "./name.js"
      export const greeting = `hello from ${name}`
      """)
      try await rig.write("/_/machines/\(id)/.agents/skills/hello/name.js", "export const name = \"studio\"")
      try await rig.run("machine-module")
      try rig.expect("machine-module")
    }
  }

  @Test func aFailedImportNamesItsChain() async throws {
    try await withRig { rig in
      try await rig.write("/skills/broken/a.js", "import \"./b.js\"")
      try await rig.write("/skills/broken/b.js", "import \"../../../outside.js\"")
      try await rig.write("/skills/broken/c.js", "import \"./missing.js\"")
      try await rig.run("module-errors")
      try await rig.run("module-missing")
      try await rig.run("module-relative")
      try await rig.run("module-system")
      try rig.expect("module-errors")
    }
  }

  @Test func anotherGroupsModuleImportsOnlyByItsQualifiedFormAndOnlyIfReadable() async throws {
    try await withRig { rig in
      try await rig.write("/skills/lib.js", "export const where = \"shared\"")
      try await rig.space.seedGroup(GroupID(rawValue: "other"))
      _ = try await rig.space.fs(GroupID(rawValue: "other")).write("/skills/lib.js", Data("export const where = \"other\"".utf8), ifMatch: nil)
      try await rig.run("module-group")
      try await rig.released()
      try await rig.run("module-foreign")
      try rig.expect("module-group")
    }
  }

  @Test func aPrivateGroupSessionImportsAndWritesInItsOwnGroupAndReachesSharedByName() async throws {
    let alice = GroupID(rawValue: "alice")
    try await withRig(group: alice) { rig in
      try await rig.write("/skills/lib.js", "export const where = \"shared\"")
      try await rig.write("/skills/shared-only.js", "export const where = \"shared\"")
      try await rig.write("/old.md", "old")
      let own = await rig.space.fs(alice)
      _ = try await own.write("/skills/lib.js", Data("export const where = \"alice\"".utf8), ifMatch: nil)
      _ = try await own.write("/draft.md", Data("draft".utf8), ifMatch: nil)
      try await rig.run("group-own")
      try await rig.released()
      try await rig.run("group-no-fallback")
      try rig.expect("group-own")
      let shared = await rig.space.fs(.shared)
      #expect(try await shared.read("/published.md").1 == Data("draft".utf8))
      await #expect(throws: (any Error).self) { try await own.stat("/draft.md") }
      await #expect(throws: (any Error).self) { try await shared.stat("/old.md") }
    }
  }

  @Test func systemModulesResolveInsideTheSystem() throws {
    #expect(try resolveScriptModule("wuhu://system/skills/x/a.js", from: "script") == "wuhu://system/skills/x/a.js")
    #expect(try resolveScriptModule("WUHU://SYSTEM/skills/x/a.js", from: "script") == "wuhu://system/skills/x/a.js")
    #expect(try resolveScriptModule("./b.js", from: "wuhu://system/skills/x/a.js") == "wuhu://system/skills/x/b.js")
    #expect(try resolveScriptModule("../y/c.js", from: "wuhu://system/skills/x/a.js") == "wuhu://system/skills/y/c.js")
    #expect(try resolveScriptModule("wuhu:/lib.js", from: "wuhu://system/skills/x/a.js") == "wuhu:/lib.js")
    #expect(throws: ScriptError.self) { try resolveScriptModule("../../../z.js", from: "wuhu://system/skills/x/a.js") }
  }

  @Test func secretsReachOnlyTheRequestItSends() async throws {
    let sent = Box<[String]>([])
    let echo = FetchClient { request in
      let body = String(decoding: try await request.body?.bytes() ?? .init(), as: UTF8.self)
      let authorization = request.headers[.authorization] ?? ""
      sent.withLock { $0 += [request.url.absoluteString, authorization, body] }
      return Response(
        status: .ok,
        headers: [.server: authorization],
        body: .string("\(request.url.absoluteString) \(authorization) \(body)"),
      )
    }
    try await withRig(fetch: echo) { rig in
      try await rig.run("secrets")
      try await rig.messages(1)
      try await rig.released()
      rig.probe("stored: \(try await rig.secrets.names())")
      try rig.expect("secrets")
    }
    #expect(sent.value == [
      "https://api.example.test/check/ghp_live_value?key=ghp_live_value",
      "Bearer ghp_live_value",
      "token=ghp_live_value&note=a%20b",
    ])
  }

  @Test func aScriptSecretIsItsGroupsAndAnotherReadGroupsOnlyByName() async throws {
    let sent = Box<[String]>([])
    let echo = FetchClient { request in
      sent.withLock { $0.append(request.url.absoluteString) }
      return Response(status: .ok, body: .string(request.url.absoluteString))
    }
    try await withRig(fetch: echo, group: GroupID(rawValue: "alice")) { rig in
      // shared's secrets open to every group that reaches it.
      try await rig.space.setSecretsScope(.reachable, of: .shared, by: (try await rig.space.ensureDevPerson()).actor, acting: .shared)
      try await rig.stores.group("shared").set("K", to: "shared-value")
      try await rig.stores.group("shared").set("S", to: "other-value")
      try await rig.run("secret-groups")
      try await rig.released()
      rig.probe("alice: \(try await rig.secrets.value(of: "K")); shared: \(try await rig.stores.group("shared").value(of: "K"))")
      try rig.expect("secret-groups")
    }
    #expect(sent.value == ["https://api.example.test/alice-value/shared-value"])
  }

  @Test func aSharedScriptNeverFallsBackIntoAGroupItDoesNotRead() async throws {
    let echo = FetchClient { request in Response(status: .ok, body: .string(request.url.absoluteString)) }
    try await withRig(fetch: echo) { rig in
      try await rig.space.seedGroup(GroupID(rawValue: "alice"))
      try await rig.stores.group("alice").set("K", to: "alice-value")
      try await rig.run("secret-no-fallback")
      try await rig.released()
      rig.probe("shared: \(try await rig.secrets.names())")
      try rig.expect("secret-no-fallback")
    }
  }

  @Test func aTaskScriptSetsAndRemovesNoSecret() async throws {
    try await withRig(task: true) { rig in
      try await rig.run("secret-task")
      try await rig.released()
      rig.probe("shared: \(try await rig.secrets.names())")
      try rig.expect("secret-task")
    }
  }

  @Test func aMachineOptionOnWuhuSecretThrowsAndTouchesNoGroup() async throws {
    try await withRig { rig in
      try await rig.run("secret-machine-option")
      try await rig.released()
      rig.probe("shared: \(try await rig.secrets.names())")
      try rig.expect("secret-machine-option")
    }
  }

  @Test func aScriptFetchCarriesNoAmbientCredential() async throws {
    let seen = Box<[[String]]>([])
    let recorder = FetchClient { request in
      seen.withLock { $0.append((Array(request.headers.values.keys) + Array(request.headers.sensitiveValues.keys)).map { $0.lowercased() }) }
      return Response(status: .unauthorized, body: .string("{}"))
    }
    try await withRig(fetch: recorder) { rig in
      try await rig.run("ambient-fetch")
      try await rig.released()
    }
    #expect(seen.value.count == 2)
    for names in seen.value {
      #expect(Set(names).isDisjoint(with: ["authorization", "cookie", "wuhu-group"]), "\(names)")
    }
  }

  @Test func readsAConversationByMessageIdOrTime() async throws {
    try await withRig { rig in
      let helper = try await makeSession(rig.space, name: "Helper")
      try await rig.space.registerPerson("u_morgan")
      _ = try await rig.space.setUserProfile(principal: "u_morgan", handle: "morgan", displayName: nil)
      let person = Sender(id: "u_morgan", timeZone: TimeZone(identifier: "Asia/Shanghai")!)
      let me = Sender(id: rig.session.rawValue, timeZone: TimeZone(identifier: "UTC")!)
      let other = Sender(id: helper.rawValue, timeZone: TimeZone(identifier: "UTC")!)
      let box = ConversationTarget.box(rig.session)
      let store = rig.space.sessions
      let folder = "/_/conversations/\(rig.session.rawValue)/attachments"
      let attached: [SessionDomain.Attachment] = [
        .image(path: "\(folder)/a.png", mimeType: "image/png", size: 4),
        .file(path: "\(folder)/b.pdf", mimeType: "application/pdf", size: 8),
      ]
      _ = try await store.post(box, messageID: MessageID("m1"), sender: person, content: .init(text: "look", attachments: attached))
      _ = try await store.post(
        box, messageID: MessageID("m2"), sender: other, senderSession: helper, replyTarget: MessageID("m1"),
        content: .init(text: "seen"),
      )
      _ = try await store.post(box, messageID: MessageID("m3"), sender: me, senderSession: rig.session, content: .init(text: "noted"))
      await rig.time.advance(by: 60)
      _ = try await store.post(box, messageID: MessageID("m4"), sender: person, content: .init(text: "later"))
      await rig.time.advance(by: 0.5)
      _ = try await store.post(box, messageID: MessageID("m5"), sender: other, senderSession: helper, content: .init(text: "half"))
      _ = try await store.post(
        .dm(with: helper.rawValue), messageID: MessageID("d1"), sender: me, senderSession: rig.session,
        content: .init(text: "psst"),
      )
      try await rig.space.seedGroup(GroupID(rawValue: "alice"))
      _ = try await rig.space.setUserProfile(principal: "u_morgan", handle: "morgan", displayName: nil)
      let theirs = try await store.createConversation(members: ["u_morgan"], in: GroupID(rawValue: "alice"))
      let ours = try await store.createConversation(members: ["u_morgan"], in: .shared)
      let foreign = try await makeSession(rig.space, name: "P", group: GroupID(rawValue: "alice"))
      try await rig.write("/fixture/ids.js", """
      export const helper = "\(helper.rawValue)"
      export const theirs = "\(theirs.rawValue)"
      export const ours = "\(ours.rawValue)"
      export const foreign = "\(foreign.rawValue)"
      """)
      // The session has taken in its box before the script reads it back.
      _ = try await store.drainQueue(rig.session)
      try await rig.run("conversation")
      try rig.expect("conversation")
    }
  }

  // Posted a little after .326, the row stores 16.326, which reads back a hair
  // under .326; a truncating format would print .325 and the cursor would
  // repeat the message.
  @Test func createdAtIsTheCursorThatExcludesItsMessage() async throws {
    let instant = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-09-26T04:28:16.326Z")
    try await withRig(prepare: { _, _ in
      @Dependency(\.timeControl) var time
      await time.advance(to: instant.addingTimeInterval(0.0002))
    }) { rig in
      let sender = Sender(id: "u_morgan", timeZone: TimeZone(identifier: "UTC")!)
      _ = try await rig.space.sessions.post(.box(rig.session), messageID: MessageID("m1"), sender: sender, content: .init(text: "one"))
      try await rig.run("conversation-created-at")
      try rig.expect("conversation-created-at")
    }
  }

  @Test func movesAndRemovesUnderTheWriteRule() async throws {
    try await withRig { rig in
      let home = "/_/sessions/\(rig.session.rawValue)"
      try await rig.write("\(home)/avatar.png", "old")
      try await rig.write("\(home)/candidate.png", "new")
      try await rig.write("/notes/a.md", "a")
      try await rig.write("/folder/keep.md", "keep")
      try await rig.write("/_/sessions/other/note.md", "theirs")
      try await rig.run("files")
      let fs = await rig.space.fs(.shared)
      rig.probe("avatar: \(String(decoding: try await fs.read("\(home)/avatar.png").1, as: UTF8.self))")
      rig.probe("candidate: \((try? await fs.read("\(home)/candidate.png")) == nil ? "gone" : "left")")
      rig.probe("other note: \(String(decoding: try await fs.read("/_/sessions/other/note.md").1, as: UTF8.self))")
      let avatar = try await rig.space.history(SpacePath(validating: "\(home)/avatar.png"), in: .shared)
      rig.probe("avatar revisions: \(avatar.map { "\($0.0.value)" }.joined(separator: ", "))")
      try rig.expect("files")
    }
  }

  @Test func aScriptFindsNoHostFunctionsOrInternals() async throws {
    try await withRig { rig in
      try await rig.run("host-hidden")
      try rig.expect("host-hidden")
    }
  }

  @Test func machineProcesses() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("machine-processes")
      try await rig.released()
      try rig.expect("machine-processes")
    }
  }

  @Test func machineChunksMaskASecretSplitAcrossThem() async throws {
    let world = MachineWorld()
    let accept = FetchClient { _ in Response(status: .ok, headers: [:], body: .string("")) }
    try await withRig(fetch: accept, world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("machine-secret-chunks")
      try await rig.released()
      try rig.expect("machine-secret-chunks")
    }
  }

  @Test func machineOutputMasksASecretSentAfterItStarted() async throws {
    let world = MachineWorld()
    let accept = FetchClient { _ in Response(status: .ok, headers: [:], body: .string("")) }
    try await withRig(fetch: accept, world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("machine-secret-late")
      try await rig.released()
      try rig.expect("machine-secret-late")
    }
  }

  @Test func machineRefusals() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      _ = try await rig.space.addMachineV2(name: "away").machine
      try await rig.run("machine-refusals")
      try await rig.released()
      try rig.expect("machine-refusals")
    }
  }

  @Test func completedUnreadProcessesReturnTheirBufferBudget() async throws {
    let world = MachineWorld()
    var limits = ScriptLimits.standard
    limits.bufferBytes = 2 * scriptProcessWindow
    try await withRig(world: world, limits: limits) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("machine-buffer-reuse")
      try await rig.released()
      try rig.expect("machine-buffer-reuse")
    }
  }

  @Test func machineLimits() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("machine-limits")
      try await rig.released()
      try rig.expect("machine-limits")
    }
  }

  @Test func aLostMachineFailsTheScriptsReadsAndFreesTheSlot() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("machine-lost")
      try await rig.released()
      try rig.expect("machine-lost")
    }
  }

  @Test func hugeWaitsAreClampedAndALifetimeKeepsItsFraction() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("script-ceilings", ["max_lifetime_seconds": .number(14400), "wait_seconds": .number(1e30)])
      try await rig.run("script-ceilings", ["max_lifetime_seconds": .number(0.5)])
      try rig.expect("script-ceilings")
    }
  }

  @Test func aLifetimePastFourHoursIsRefusedNotClamped() async throws {
    try await withRig { rig in
      for lifetime in [14400.5, 1e30] {
        guard case let .failure(refused) = try await rig.payload(["source": "result('never')", "max_lifetime_seconds": .number(lifetime)]) else {
          Issue.record("max_lifetime_seconds \(lifetime) was accepted")
          continue
        }
        #expect(refused.code == "invalidArgument")
        #expect(refused.message == "run_script: max_lifetime_seconds is at most 14400")
      }
      try await rig.released()
    }
  }

  @Test func aLifetimeOfZeroOrLessIsAnInvalidArgument() async throws {
    try await withRig { rig in
      for lifetime in [0.0, -5] {
        guard case let .failure(refused) = try await rig.payload(["source": "result('never')", "max_lifetime_seconds": .number(lifetime)]) else {
          Issue.record("max_lifetime_seconds \(lifetime) was accepted")
          continue
        }
        #expect(refused.code == "invalidArgument")
        #expect(refused.message == "run_script: max_lifetime_seconds must be positive")
      }
      try await rig.released()
    }
  }

  @Test func machineFiles() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("machine-files")
      try rig.expect("machine-files")
    }
  }

  @Test func machineCopy() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("machine-copy")
      let asked = world.files.copies.value.map { target in
        switch target {
        case let .caller(limit): "caller(limit: \(limit))"
        case let .machine(_, path, replace): "machine(\(path), replace: \(replace))"
        }
      }
      rig.probe("seam asked: \(asked.joined(separator: ", "))")
      try rig.expect("machine-copy")
    }
  }

  @Test func aCommandWhoseCallerLeavesKillsItsProcessAndReleasesItsRows() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      let (said, say) = AsyncStream<ScriptOutput>.makeStream()
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          try? await rig.command("""
          import { machine } from "wuhu:machine"
          const sleeper = await machine("box").spawn("sleep-ready")
          for await (const line of sleeper.lines()) break
          result(`spawned ${sleeper.id}`)
          await sleeper.wait()
          """) { say.yield($0) }
        }
        for await output in said {
          if case .result = output { break }
        }
        group.cancelAll()
      }
      #expect(world.execs.kills.value.count == 1)
      try await until("the closed caller retires its exec") { try await rig.scriptExecRows() == 0 }
    }
  }

  @Test(.timeLimit(.minutes(1))) func closingKillsBusyScripts() async throws {
    try await withRig { rig in
      let busy = #"result("started"); while (true) {}"#
      #expect(try await rig.evaluate(busy) == .string("started"))
      let (said, say) = AsyncStream<ScriptOutput>.makeStream()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await rig.command(busy) { say.yield($0) } }
        for await output in said {
          if case .result = output { break }
        }
        await rig.worker.quiesce()
        try await group.waitForAll()
      }
    }
  }

  @Test func autoRelease() async throws {
    try await withRig { rig in
      try await rig.run("auto-release")
      try await rig.time.wake("the script's timer", after: 1)
      try await rig.messages(1)
      try await rig.released()
      try rig.expect("auto-release")
    }
  }
}

private let fixtures = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().appendingPathComponent("Fixtures/Scripts")

private func fixture(_ name: String) throws -> String {
  String(decoding: try Data(contentsOf: fixtures.appendingPathComponent(name)), as: UTF8.self)
}

final class ScriptRig: Sendable {
  let space: Space
  let scripts: Scripts
  let worker: SessionExecution
  let main: Hub
  /// The rig session's own group's secrets.
  let secrets: SpaceSecrets
  let stores: SpaceSecretStores
  let session: SessionID
  let time: TimeControl
  let group: GroupID
  private let executor: ToolExecutor
  private let entries = Box<[String]>([])
  private let seen = Box(0)
  private let calls = Box(0)
  private let lastScript = Box<String?>(nil)
  var scriptID: String { lastScript.value! }

  init(
    space: Space, main: Hub, scripts: Scripts, stores: SpaceSecretStores, group: GroupID, session: SessionID, time: TimeControl,
    executor: ToolExecutor, worker: SessionExecution,
  ) throws {
    self.space = space
    self.main = main
    self.scripts = scripts
    self.stores = stores
    secrets = try stores.group(group.rawValue)
    self.group = group
    self.session = session
    self.time = time
    self.executor = executor
    self.worker = worker
  }

  func record(_ label: String, _ text: String) {
    entries.withLock { $0.append("=== \(label)\n\(text)") }
  }

  func probe(_ text: String) {
    record("probe", text)
  }

  func run(_ name: String, _ options: OrderedDictionary<String, JSONValue> = [:]) async throws {
    var arguments = options
    arguments["source"] = .string(try fixture(name + ".js"))
    record("run_script", try await call("run_script", arguments))
  }

  /// Runs `source` as `wuhu script` runs a file: for this caller alone.
  func command(_ source: String, output: @escaping @Sendable (ScriptOutput) -> Void) async throws {
    try await scripts.run(ScriptRun(runner: .session(session, group: GroupID(rawValue: "g")), source: source, arguments: []), tools: executor, output: output)
  }

  func evaluate(_ source: String) async throws -> JSONValue {
    let output = try await call("run_script", ["source": .string(source)])
    let first = String(output.prefix { $0 != "\n" })
    return JSONValue.parse(first) ?? .string(first)
  }

  func write(_ path: String, _ text: String) async throws {
    let group: GroupID = ["/models.json", "/model-groups.json", "/capabilities.json"].contains(path) ? .settings : .shared
    _ = try await space.fs(group).write(path, Data(text.utf8), ifMatch: nil)
  }

  /// The rig group's cell has taken the attempts its mail carried on their way.
  func deliverInferences() async throws {
    let id = GroupCell.ID(group.rawValue)
    while space.worker.hasMail(for: id.recipient) { await Task.yield() }
    try await space.worker.call(id) { _ in () }
  }

  /// A cancel with its failure code shown, from `caller` (the rig's session
  /// by default).
  func cancel(_ id: String, as caller: SessionID? = nil) async throws {
    let payload = try await executor.execute(
      session: caller ?? session,
      call: ToolCall(id: "cancel-\(id)", name: "cancel", arguments: .object(["id": .string(id)])),
      state: ToolExecutionState(),
    ).payload
    switch payload {
    case let .script(result): record("cancel", result.output)
    case let .failure(failure): record("cancel", "failed (\(failure.code ?? "no code")): \(failure.message)")
    default: throw Mismatch("unexpected payload \(payload)")
    }
  }

  func stop(_ id: String) async throws {
    record("cancel", try await call("cancel", ["id": .string("script.\(id)")]))
  }

  func payload(_ arguments: OrderedDictionary<String, JSONValue>, tool name: String = "run_script") async throws -> ToolResultPayload {
    let id = calls.withLock {
      $0 += 1
      return "tc-\($0)"
    }
    let call = ToolCall(id: id, name: name, arguments: .object(arguments))
    guard name == "run_script" else {
      return try await executor.execute(session: session, call: call, state: ToolExecutionState()).payload
    }
    do { _ = try ScriptPlan(call) }
    catch let error as ToolProblem { return .failure(.init(message: error.message, code: error.code)) }
    let handle = try await space.worker.call(SessionCell.ID(session.rawValue)) { cell in
      let hydration = try cell.hydrate(self.session)
      var turn = cell.turn() ?? SessionTurn(generation: hydration.generation, position: 1)
      turn.position += 1
      turn.turn = .tools(calls: [call])
      turn.replied = true
      turn.armed = true
      try cell.db.execute(SessionTurn.delete())
      try cell.db.execute(SessionTurn.insert { turn })
      let slot = Slot(session: self.session, generation: turn.generation, position: turn.position, stepTry: 0)
      try cell.startScript(slot.call, call, ScriptPlan(call))
      return String(cell.scriptAt(slot.call.key)!.key.split(separator: ":").last!.dropFirst("script.".count))
    }
    lastScript.withLock { $0 = handle }
    var answer: ToolResultPayload?
    try await until("the script tool answers") {
      for stored in try await self.space.sessions.transcriptLines(self.session) where stored.key == "call:\(id)" {
        guard case let .toolResult(result) = try stored.line().message else { continue }
        let text = result.content.compactMap { if case let .text(text) = $0 { text.text } else { nil } }.joined()
        answer = result.isError ? .failure(.init(message: text)) : .script(.init(output: text))
      }
      return answer != nil
    }
    return answer!
  }

  private func call(_ name: String, _ arguments: OrderedDictionary<String, JSONValue>) async throws -> String {
    let payload = try await payload(arguments, tool: name)
    switch payload {
    case let .script(result): return result.output
    case let .failure(failure): return "failed: " + failure.message
    default: throw Mismatch("unexpected payload \(payload)")
    }
  }

  func delivered() async throws -> [String] {
    try await until("the rig's session takes its mail") {
      !space.worker.hasMail(for: SessionCell.ID(self.session.rawValue).recipient)
    }
    return try await space.sessions.undrainedInputs(session).compactMap { entry in
      guard case let .notification(notification) = entry.input, notification.kind == .script else { return nil }
      return notification.content.text
    }.dropFirst(seen.value).map(\.self)
  }

  func messages(_ total: Int) async throws {
    do {
      try await until("\(total) script messages") {
        try await delivered().count + seen.value >= total
      }
    } catch {
      try await recordDelivered()
      Issue.record("transcript so far:\n\(entries.value.joined(separator: "\n"))")
      throw error
    }
    try await recordDelivered()
  }

  private func recordDelivered() async throws {
    for text in try await delivered() {
      seen.withLock { $0 += 1 }
      record("message", text)
    }
  }

  func scriptExecRows() async throws -> Int {
    try await space.machines().reduce(0) { count, machine in
      count + space.worker.cell(MachineCell.ID(machine.id.rawValue)).pendingScriptExecs()
    }
  }

  func running() -> [String] { space.worker.cell(SessionCell.ID(session.rawValue)).runningScripts() }

  func released() async throws {
    try await until("the execution is released") { running().isEmpty }
  }

  func children(of parent: SessionID, _ specs: [(title: String, model: String)]) async throws -> [SessionID] {
    var children: [SessionID] = []
    for spec in specs {
      let provider = spec.model.hasPrefix("claude") ? "claude" : "codex"
      children.append(try await space.sessions.createSession(
        group: .shared,
        title: spec.title,
        kind: .task,
        parent: parent,
        createdBy: "morgan",
        executor: .kernel(.init(provider: provider, model: spec.model, effort: "high")),
      ))
    }
    return children
  }

  func activity(_ session: SessionID, hoursAgo: Double) async throws {
    // The sample queries against JavaScript Date.now(), not the fixture clock.
    let at = SQLiteDateFormat.string(from: Date().addingTimeInterval(-hoursAgo * 3600))
    try await space.worker.call(SessionCell.ID(session.rawValue)) { cell in
      try cell.db.execute(ScriptActivityRow.where { $0.id.eq(session.rawValue) }.update { $0.lastActivityAt = #bind(at) })
    }
  }

  func expect(_ name: String) throws {
    let actual = (entries.value.joined(separator: "\n") + "\n").replacingOccurrences(of: session.rawValue, with: "<me>")
    let expected = try fixture(name + ".expected")
    #expect(normalizingExecIDs(actual) == normalizingExecIDs(expected), "\(name).expected differs; actual transcript:\n\(actual)")
  }
}

// A machine for wuhu:machine: FakeMachineFS for files, `playbook` for processes.
final class MachineWorld: Sendable {
  let files = FakeMachineFS()
  let execs = ScriptedExecMachine()

  func attach(_ name: String, in space: Space) async throws {
    let id = try await space.addMachineV2(name: name).machine.id
    _ = files.attached.withLock { $0.insert(id) }
  }
}

// What each command does on the scripted machine.
private let playbook: @Sendable (IncomingExec, ScriptedExecMachine) async -> Void = { exec, machine in
  switch exec.start.command.last ?? "" {
  case "build":
    try? await exec.send(.stdout, Array("compiling\nlink".utf8))
    try? await exec.send(.stderr, Array("warning: slow disk\n".utf8))
    try? await exec.send(.stdout, Array("ing\r\ndone".utf8))
    await exec.exit(.exited(code: 0))
  case "bytes":
    try? await exec.send(.stdout, [0xFF, 0x00, 0x41])
    try? await exec.send(.stderr, [0x0A])
    await exec.exit(.exited(code: 0))
  case "split-secret":
    try? await exec.send(.stdout, Array("fake-".utf8))
    try? await exec.send(.stderr, Array("e1".utf8))
    try? await exec.send(.stdout, Array("key\n|fake-key\\".utf8))
    try? await exec.send(.stderr, Array("e2".utf8))
    try? await exec.send(.stdout, Array("n|fake-key".utf8))
    await exec.exit(.exited(code: 0))
  case "upper":
    do {
      for try await chunk in exec.stdin {
        try await exec.send(.stdout, Array(String(decoding: chunk, as: UTF8.self).uppercased().utf8))
      }
      try await exec.send(.stdout, [0x0A])
    } catch {}
    await exec.exit(.exited(code: 0))
  case "env":
    let env = (exec.start.env?.entries ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    let secrets = (exec.start.secrets?.entries ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)<-\($0.value)" }
    try? await exec.send(.stdout, Array("cwd \(exec.start.cwd); env \(env); secrets \(secrets)\n".utf8))
    try? await exec.send(.stderr, Array("timeout \(exec.start.timeout.map { "\($0)" } ?? "none")\n".utf8))
    await exec.exit(.exited(code: 3))
  case "flood":
    let chunk = [UInt8](repeating: 0x78, count: 64 << 10)
    for _ in 0 ..< 48 {
      try? await exec.send(.stdout, chunk)
    }
    try? await exec.send(.stdout, Array("\nend\n".utf8))
    await exec.exit(.exited(code: 0))
  case "noisy":
    // Stops at maxOutput as the agent does.
    let text = Array("maxOutput \(exec.start.maxOutput.map(String.init) ?? "none")\n".utf8)
      + [UInt8](repeating: 0x2E, count: 16)
    try? await exec.send(.stdout, Array(text.prefix(exec.start.maxOutput ?? .max)))
    await exec.exit(.exited(code: 0))
  case "vanish":
    // Gone once the script has read the first line and says so on stdin.
    try? await exec.send(.stdout, Array("ready\n".utf8))
    var input = exec.stdin.makeAsyncIterator()
    _ = try? await input.next()
    await machine.lose(exec.start.id)
    for await _ in exec.kills {}
  case "sleep", "sleep-ready":
    if exec.start.command.last == "sleep-ready" { try? await exec.send(.stdout, Array("ready\n".utf8)) }
    for await _ in exec.kills {
      await exec.exit(.signaled(signal: 15))
      return
    }
  default:
    await exec.exit(.exited(code: 0))
  }
}

func withRig(
  space: () throws -> Space = { try Space.inMemory() },
  fetch: FetchClient? = nil,
  machineHub: MachineHub? = nil,
  machines: MachineSeam? = nil,
  world: MachineWorld? = nil,
  identity: IdentityController? = nil,
  contentHost: String? = nil,
  credentials: CredentialResolver = .unavailable,
  resolveModelExecutor: (@Sendable (String, String, String?) async throws -> SessionExecutor)? = nil,
  resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)? = nil,
  prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)? = nil,
  group: GroupID = .shared,
  task: Bool = false,
  childAgent: Bool = false,
  prepare: (Space, SessionID) async throws -> Void = { _, _ in },
  limits: ScriptLimits = .standard,
  _ body: @escaping (ScriptRig) async throws -> Void,
) async throws {
  try await withToolDeps { time in
    try await withDependencies {
      if let fetch { $0.fetch = fetch }
    } operation: {
      let space = try space()
      let scripts = Scripts(limits: limits)
      let access = InferenceAccess(credentials: credentials)
      let loop = try await ToolFixture(space: space, access: access, scripts: scripts)
      if group != .shared {
        try await space.seedGroup(group)
      }
      var session = try await makeSession(space, group: group)
      try await space.worker.call(SessionCell.ID(session.rawValue)) { try $0.interrupt() }
      if task || childAgent {
        session = try await space.sessions.createSession(
          group: group, title: "child", kind: task ? .task : .agent, parent: session, createdBy: session.rawValue,
          executor: .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
        )
        try await space.worker.call(SessionCell.ID(session.rawValue)) { try $0.interrupt() }
      }
      let folder = try scratchURL("script-secrets")
      defer { try? FileManager.default.removeItem(at: folder) }
      let stores = SpaceSecretStores(configDirectory: folder, spaceID: "spc_test")
      try await prepare(space, session)
      let main = loop.hub { Hub(space: space, secrets: stores, machines: machines ?? world?.files.seam, resolveModelExecutor: resolveModelExecutor, resolveModelGroup: resolveModelGroup, prepareModelRoute: prepareModelRoute) }
      let origin = contentHost.map { _ in "https://space.test" }
      if let world {
        _ = try await world.execs.executor(
          owner: main, loop: loop, access: access,
          origin: origin, contentHostPattern: contentHost, secrets: stores, identity: identity,
        )
      } else {
        _ = try await loop.executor(
          owner: main, hub: machineHub, access: access,
          origin: origin, contentHostPattern: contentHost, secrets: stores, identity: identity,
        )
      }
      let worker = loop.execution
      worker.start()
      let rig = try ScriptRig(
        space: space, main: main, scripts: scripts, stores: stores, group: group, session: session, time: time, executor: worker.tools, worker: worker,
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          await whenCancelled { await worker.shutdown() }
        }
        if let world {
          group.addTask { await world.execs.pump() }
          group.addTask { await world.execs.serve { await playbook($0, world.execs) } }
        }
        defer { group.cancelAll() }
        try await body(rig)
      }
    }
  }
}

private let githubStub = FetchClient { request in
  #expect(request.method.rawValue == "GET")
  #expect(request.url.absoluteString == "https://api.github.com/repos/quickjs-ng/quickjs/releases/latest")
  #expect(request.headers.values == ["accept": "application/vnd.github+json", "user-agent": "wuhu-run-script"])
  return Response(
    status: .ok,
    body: .string(#"{"tag_name":"v0.16.0","published_at":"2026-09-01T00:00:00Z"}"#),
  )
}

private func tracedSpace(_ executed: @escaping @Sendable (String) -> Void) throws -> Space {
  try Space.inMemory(configuration: Space.makeConfiguration(journalMode: .default), trace: executed)
}

private func normalizingExecIDs(_ text: String) -> String {
  let text = text.replacingOccurrences(of: #"script\.(?!ffffffff)[a-f0-9]{8}"#, with: "script.00000000", options: .regularExpression)
  let tokens = text.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
  var aliases: [String: String] = [:]
  var normalized = text
  for token in tokens where token.hasPrefix("ex_") && token.count == 11 {
    let id = String(token)
    if aliases[id] == nil {
      let alias = "<exec-\(aliases.count + 1)>"
      aliases[id] = alias
      normalized = normalized.replacingOccurrences(of: id, with: alias)
    }
  }
  return normalized
}

@Table("sessions")
private struct ScriptActivityRow {
  let id: String
  @Column("last_activity_at") var lastActivityAt: String
}

extension MachineCell {
  fileprivate func pendingScriptExecs() -> Int {
    db.rows(MachineOperation.live).filter { !$0.delivered && $0.request.script != nil }.count
  }
}
