import Clocks
import ControlledTime
import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecrets
import struct Credentials.SpaceSecretStores
import Dependencies
import Fetch
import Foundation
import GRDB
import JSONValue
import MachineChannel
import struct MachineContract.MachineID
import OrderedCollections
import Scratch
import SessionDomain
@testable import SessionTools
import struct SpaceContract.GroupID
@testable import SpaceCore
import struct SpaceFS.SpacePath
import struct SpaceTools.MachineSeam
import Testing
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall

// Each test runs one script from Fixtures/Scripts and compares its transcript —
// every tool result, every message the script sent, and the harness's own
// probes, in order — with the checked-in <name>.expected.
@Suite struct ScriptTests {
  @Test func sample() async throws {
    let watchQueries = Box(0)
    let space = {
      try tracedSpace { sql in
        if sql.contains("lifecycle != 'archived'") { watchQueries.withLock { $0 += 1 } }
      }
    }
    try await withRig(space: space, fetch: githubStub) { rig in
      try await rig.children(of: rig.session, [
        ("Port QuickJS kit", "claude-opus-5-5"),
        ("Review the gater", "gpt-5.6-sol"),
        ("Flaky CI sweep", "claude-opus-5-5"),
        ("Old migration", "claude-opus-5-5"),
      ])
      try await rig.apply("sample.sql")
      try await rig.run("sample", ["timeout_seconds": 60, "on_timeout": "detach"])

      try await until("the watch list is read") { watchQueries.value > 0 }
      try await rig.apply("sample-done.sql")
      try await rig.messages(1)
      try await rig.apply("sample-failed.sql")
      try await rig.messages(3)
      try await rig.released()
      try rig.expect("sample")
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
    let twentyMegabytes = FetchClient { _ in
      Response(status: .ok, body: .string(String(repeating: "x", count: 20 << 20)))
    }
    try await withRig(fetch: twentyMegabytes) { rig in
      try await rig.run("budget")
      try await rig.released()
      try rig.expect("budget")
    }
  }

  @Test func stopScript() async throws {
    try await withRig { rig in
      try await rig.run("stop")
      try await rig.stop(scriptID)
      try await rig.messages(1)
      try await rig.released()
      try rig.expect("stop")
    }
  }

  @Test func stopScriptKillsAScriptThatIgnoresIt() async throws {
    try await withRig { rig in
      try await rig.run("stop-ignored")
      try await rig.advancing { try await rig.stop(scriptID) }
      try await rig.released()
      try await holds("nothing more is sent") { try await rig.delivered().isEmpty }
      try rig.expect("stop-ignored")
    }
  }

  @Test func timeoutKills() async throws {
    try await withRig { rig in
      try await rig.advancing {
        try await rig.run("timeout", ["timeout_seconds": 30, "on_timeout": "kill"])
      }
      try await rig.released()
      try rig.expect("timeout-kill")
    }
  }

  @Test func timeoutDetaches() async throws {
    try await withRig { rig in
      try await rig.advancing {
        try await rig.run("timeout", ["timeout_seconds": 30, "on_timeout": "detach"])
      }
      try await rig.messages(1)
      try await rig.released()
      try rig.expect("timeout-detach")
    }
  }

  @Test func timeoutSparesAScriptThatAnswered() async throws {
    try await withRig { rig in
      try await rig.advancing {
        try await rig.run("busy-after-result", ["timeout_seconds": 30, "on_timeout": "kill"])
      }
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
      let id = try await rig.space.addMachine(name: "studio").id.rawValue
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
      try await rig.space.writer.write { db in
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('other', '2026-01-01T00:00:00.000Z')")
      }
      _ = try await rig.space.fs(GroupID(rawValue: "other")).write("/skills/lib.js", Data("export const where = \"other\"".utf8), ifMatch: nil)
      try await rig.run("module-group")
      try await rig.released()
      try await rig.run("module-foreign")
      try rig.expect("module-group")
    }
  }

  @Test func aPersonalGroupSessionImportsAndWritesInItsOwnGroupAndReachesSharedByName() async throws {
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
      try await rig.space.writer.write { db in
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('alice', '2026-01-01T00:00:00.000Z')")
      }
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
      let theirs = try await store.createConversation(members: [helper.rawValue, "u_morgan"], in: .shared)
      let ours = try await store.createConversation(members: [rig.session.rawValue, helper.rawValue], in: .shared)
      try await rig.space.writer.write { db in
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('alice', '2026-01-01T00:00:00.000Z')")
      }
      let foreign = try await makeSession(rig.space, name: "P", group: GroupID(rawValue: "alice"))
      try await rig.write("/fixture/ids.js", """
      export const helper = "\(helper.rawValue)"
      export const theirs = "\(theirs.rawValue)"
      export const ours = "\(ours.rawValue)"
      export const foreign = "\(foreign.rawValue)"
      """)
      try await rig.run("conversation")
      try rig.expect("conversation")
    }
  }

  // Posted a little after .326, the row stores 16.326, which reads back a hair
  // under .326; a truncating format would print .325 and the cursor would
  // repeat the message.
  @Test func createdAtIsTheCursorThatExcludesItsMessage() async throws {
    try await withRig { rig in
      let sender = Sender(id: "u_morgan", timeZone: TimeZone(identifier: "UTC")!)
      let instant = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-09-26T04:28:16.326Z")
      await rig.time.advance(to: instant.addingTimeInterval(0.0002))
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

  @Test func machineRefusals() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      _ = try await rig.space.addMachine(name: "away")
      try await rig.run("machine-refusals")
      try await rig.released()
      rig.probe("killed when the script ended: \(world.execs.kills.value.count) of \(world.execs.startCount.value)")
      rig.probe("owner rows left: \(try await rig.scriptExecRows())")
      try rig.expect("machine-refusals")
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
      rig.probe("killed when the script ended: \(world.execs.kills.value.count) of \(world.execs.startCount.value)")
      try rig.expect("machine-lost")
    }
  }

  @Test func hugeWaitsAreClampedAndALifetimeKeepsItsFraction() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("script-ceilings", ["max_lifetime_seconds": .number(1e30), "timeout_seconds": .number(1e30)])
      try await rig.run("script-ceilings", ["max_lifetime_seconds": .number(0.5)])
      try rig.expect("script-ceilings")
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

  @Test func aProcessDiesWithTheScriptThatStartedIt() async throws {
    let world = MachineWorld()
    try await withRig(world: world) { rig in
      try await world.attach("box", in: rig.space)
      try await rig.run("machine-orphan")
      try await rig.released()
      rig.probe("killed: \(world.execs.kills.value.map(\.rawValue))")
      rig.probe("owner rows left: \(try await rig.scriptExecRows())")
      try rig.expect("machine-orphan")
    }
  }

  @Test func aRestartTellsEachOwnerItsScriptIsGone() async throws {
    try await withRig(prepare: { space, session in
      let box = try await space.addMachine(name: "box").id
      let other = try await makeSession(space, name: "other")
      _ = try await space.mintScriptExec(machine: box, session: session.rawValue, script: "0badf00d")
      let done = try await space.mintScriptExec(machine: box, session: session.rawValue, script: "0badf00d")
      try await space.finishExec(done.id, .exited(code: 0))
      _ = try await space.mintScriptExec(machine: box, session: session.rawValue, script: "cafe0000")
      _ = try await space.mintScriptExec(machine: box, session: other.rawValue, script: "feed0000")
    }) { rig in
      try await rig.messages(2)
      rig.probe("owner rows left: \(try await rig.scriptExecRows())")
      try rig.expect("restart-notice")
    }
  }

  @Test func autoRelease() async throws {
    try await withRig { rig in
      try await rig.run("auto-release")
      try await rig.messages(1)
      try await rig.released()
      try rig.expect("auto-release")
    }
  }
}

let scriptID = "00000000"

private let fixtures = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().appendingPathComponent("Fixtures/Scripts")

private func fixture(_ name: String) throws -> String {
  String(decoding: try Data(contentsOf: fixtures.appendingPathComponent(name)), as: UTF8.self)
}

final class ScriptRig: Sendable {
  let space: Space
  let scripts: Scripts
  /// The rig session's own group's secrets.
  let secrets: SpaceSecrets
  let stores: SpaceSecretStores
  let session: SessionID
  let time: TimeControl
  private let executor: ToolExecutor
  private let entries = Box<[String]>([])
  private let seen = Box(0)
  private let calls = Box(0)

  init(
    space: Space, scripts: Scripts, stores: SpaceSecretStores, group: GroupID, session: SessionID, time: TimeControl,
    executor: ToolExecutor,
  ) throws {
    self.space = space
    self.scripts = scripts
    self.stores = stores
    secrets = try stores.group(group.rawValue)
    self.session = session
    self.time = time
    self.executor = executor
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

  func write(_ path: String, _ text: String) async throws {
    _ = try await space.fs(.shared).write(path, Data(text.utf8), ifMatch: nil)
  }

  func stop(_ id: String) async throws {
    record("stop_script", try await call("stop_script", ["id": .string(id)]))
  }

  private func call(_ name: String, _ arguments: OrderedDictionary<String, JSONValue>) async throws -> String {
    let id = calls.withLock {
      $0 += 1
      return "tc-\($0)"
    }
    let payload = try await executor.execute(
      session: session,
      call: ToolCall(id: id, name: name, arguments: .object(arguments)),
      state: ToolExecutionState(),
    )
    switch payload {
    case let .script(result): return result.output
    case let .failure(failure): return "failed: " + failure.message
    default: throw Mismatch("unexpected payload \(payload)")
    }
  }

  func delivered() async throws -> [String] {
    try await space.sessions.hydrate(session).undrained.compactMap { entry in
      guard case let .notification(notification) = entry.input, notification.kind == .script else { return nil }
      return notification.content.text
    }.dropFirst(seen.value).map(\.self)
  }

  func messages(_ total: Int) async throws {
    do {
      try await untilAdvancing("\(total) script messages", time) {
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
    try await space.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM script_execs") ?? 0 }
  }

  func released() async throws {
    try await untilAdvancing("the execution is released", time) { scripts.isIdle }
  }

  // Runs `body` while nudging the clock a second at a time, for a call that
  // waits on a timer without the test naming its offset. `ControlledTime.wake`
  // could advance to it exactly instead.
  func advancing<R: Sendable>(_ body: @Sendable @escaping () async throws -> R) async throws -> R {
    try await withThrowingTaskGroup(of: R?.self) { group in
      group.addTask { try await body() }
      group.addTask { [time] in
        let clock = ContinuousClock()
        while !Task.isCancelled {
          await time.advance(by: 1)
          try? await clock.sleep(for: .milliseconds(2))
        }
        return nil
      }
      defer { group.cancelAll() }
      while let next = try await group.next() {
        if let next { return next }
      }
      throw Mismatch("the advancing call never finished")
    }
  }

  func children(of parent: SessionID, _ specs: [(title: String, model: String)]) async throws {
    for spec in specs {
      let provider = spec.model.hasPrefix("claude") ? "claude" : "codex"
      try await space.sessions.createSession(
        group: .shared,
        title: spec.title,
        kind: .task,
        parent: parent,
        createdBy: "morgan",
        executor: .kernel(.init(provider: provider, model: spec.model, effort: "high")),
      )
    }
  }

  func apply(_ name: String) async throws {
    let sql = try fixture(name)
    try await space.writer.write { try $0.execute(sql: sql) }
  }

  func expect(_ name: String) throws {
    let actual = entries.value.joined(separator: "\n") + "\n"
    let expected = try fixture(name + ".expected")
    #expect(actual == expected, "\(name).expected differs; actual transcript:\n\(actual)")
  }
}

// A machine for wuhu:machine: FakeMachineFS for files, `playbook` for processes.
final class MachineWorld: Sendable {
  let files = FakeMachineFS()
  let execs = ScriptedExecMachine()

  func attach(_ name: String, in space: Space) async throws {
    let id = try await space.addMachine(name: name).id
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
  case "sleep":
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
  machines: MachineSeam? = nil,
  world: MachineWorld? = nil,
  credentials: CredentialResolver = .unavailable,
  resolveModelExecutor: (@Sendable (String, String, String?) async throws -> SessionExecutor)? = nil,
  control: SessionControl? = nil,
  group: GroupID = .shared,
  task: Bool = false,
  prepare: (Space, SessionID) async throws -> Void = { _, _ in },
  _ body: @escaping (ScriptRig) async throws -> Void,
) async throws {
  try await withToolDeps { time in
    try await withDependencies {
      if let fetch { $0.fetch = fetch }
    } operation: {
      let space = try space()
      if group != .shared {
        try await space.writer.write { db in
          try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2026-01-01T00:00:00.000Z')", arguments: [group.rawValue])
        }
        try await space.addEdge(src: group, dst: .shared, kind: .read, by: nil)
      }
      var session = try await makeSession(space, group: group)
      if task {
        session = try await space.sessions.createSession(
          group: group, title: "task", kind: .task, parent: session, createdBy: session.rawValue,
          executor: .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
        )
      }
      let folder = try scratchURL("script-secrets")
      defer { try? FileManager.default.removeItem(at: folder) }
      let stores = SpaceSecretStores(configDirectory: folder, spaceID: "spc_test")
      try await prepare(space, session)
      let access = world.map { ScriptMachineAccess(files: $0.files.seam, exec: $0.execs.backend(space)) }
      let scripts = Scripts(space: space, secrets: stores, machines: access)
      let executor = ToolExecutor(
        space: space, machines: machines, resolveModelExecutor: resolveModelExecutor,
        credentials: credentials, scripts: scripts, control: control,
      )
      let rig = try ScriptRig(
        space: space, scripts: scripts, stores: stores, group: group, session: session, time: time, executor: executor,
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripts.run() }
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
  try Space.temporary(trace: executed)
}
