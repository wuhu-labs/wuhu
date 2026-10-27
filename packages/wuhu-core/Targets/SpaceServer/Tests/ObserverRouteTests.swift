import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import MachineContract
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

// A group's observers over HTTP: write on the group arms and cancels, read
// lists, and a firing's own token reaches none of it; a firing uses its
// group's machines through its script.
@Suite(.deterministicDependencies) struct ObserverRouteTests {
  func delete(_ harness: SessionHarness, _ path: String) async throws -> Response {
    try await harness.api(Request(url: URL(string: "http://space\(path)")!, method: .delete))
  }

  func code(_ response: Response) async throws -> String? {
    JSONValue.parse(try await response.text())?.object?["code"]?.stringValue
  }

  @Test func createListCancelAndRefusals() async throws {
    try await withSessionDeps {
      let tokens = ExecTokens(spaceURL: "http://space")
      let harness = try await SessionHarness(execTokens: tokens)
      let body: JSONValue = ["name": "nightly", "handler": "/nightly.js", "timer": ["cron": "0 3 * * *"], "sessionsPerHour": 3]
      let created = try await harness.post("/v1/group/shared/observers", body)
      let createdText = try await created.text()
      #expect(created.status == .created, "\(createdText)")
      let output = try JSONValueDecoder().decode(ObserverOutput.self, from: try #require(JSONValue.parse(createdText)))
      #expect(output.name == "nightly")
      #expect(output.group == "shared")
      #expect(output.kind == .timer)
      #expect(output.cron == "0 3 * * *")
      #expect(output.status == .armed)
      #expect(output.sessionsPerHour == 3)
      #expect(output.id.hasPrefix("timer."))

      let again = try await harness.post("/v1/group/shared/observers", body)
      #expect(again.status == .conflict)
      #expect(try await code(again) == "conflict")
      let badName = try await harness.post("/v1/group/shared/observers", ["name": "Nightly", "handler": "/n.js", "timer": ["cron": "0 3 * * *"]])
      #expect(try await code(badName) == "invalidArgument")
      let both = try await harness.post("/v1/group/shared/observers", ["name": "both", "handler": "/n.js", "timer": ["inSeconds": 5], "observe": ["sql": "SELECT 1"]])
      #expect(try await code(both) == "invalidArgument")
      #expect(try await harness.post("/v1/group/nowhere/observers", body).status == .notFound)

      let alice = try await harness.space.addAccount(kind: .human, name: "alice")
      let foreign = try await harness.space.ensurePersonalGroup(account: alice.id)
      let session = try await harness.store.createSession(
        group: .shared, title: "agent", kind: .agent, createdBy: "owner",
        executor: .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")),
      )
      let outsider = try await harness.post("/v1/group/\(foreign.rawValue)/observers", body, bearer: tokens.sessionToken(session))
      #expect(outsider.status == .forbidden)
      #expect(try await harness.store.observers(foreign).isEmpty)

      let firing = tokens.firingToken(Observer(group: .shared, name: "nightly", firing: "f1"))
      for refused in [
        try await harness.get("/v1/group/shared/observers", bearer: firing),
        try await harness.post("/v1/group/shared/observers", body, bearer: firing),
        try await harness.post("/v1/session/\(SessionID("anyone").rawValue)/archive", .null, bearer: firing),
      ] {
        #expect(refused.status == .forbidden)
      }

      let listed = try await harness.get("/v1/group/shared/observers")
      let observers = try JSONValueDecoder().decode(ObserversOutput.self, from: try #require(JSONValue.parse(try await listed.text())))
      #expect(observers.observers == [output])

      let cancelled = try await delete(harness, "/v1/group/shared/observers/nightly")
      #expect(cancelled.status == .ok)
      #expect(try await delete(harness, "/v1/group/shared/observers/nightly").status == .notFound)
      #expect(try await harness.store.observers(.shared).isEmpty)
    }
  }

  @Test func aFiringUsesItsGroupsMachinesAndOwnsWhatItsScriptMints() async throws {
    try await withSessionDeps {
      let tokens = ExecTokens(spaceURL: "http://space")
      let harness = try await SessionHarness(execTokens: tokens)
      let common = try await harness.space.addMachine(name: "common").id
      let alice = try await harness.space.addAccount(kind: .human, name: "alice")
      let hers = try await harness.space.addMachine(name: "hers", group: try await harness.space.ensurePersonalGroup(account: alice.id)).id
      let firing = tokens.firingToken(Observer(group: .shared, name: "nightly", firing: "f1"))

      let listed = try await harness.get("/v1/machine", bearer: firing)
      #expect(listed.status == .ok)
      let machines = try JSONValueDecoder().decode([MachineStatus].self, from: try #require(JSONValue.parse(try await listed.text())))
      #expect(machines.compactMap(\.name) == ["common"])
      #expect(try await harness.get("/v1/machine/hers/status", bearer: firing).status == .notFound)

      #expect(try await harness.post("/v1/exec", ["machine": .string(common.rawValue)], bearer: firing).status == .forbidden)
      #expect(try await harness.post("/v1/exec", ["machine": .string(hers.rawValue), "script": "s1"], bearer: firing).status == .notFound)
      let minted = try await harness.post("/v1/exec", ["machine": .string(common.rawValue), "script": "s1"], bearer: firing)
      #expect(minted.status == .ok)
      let id = try JSONValueDecoder().decode(ExecMintOutput.self, from: try #require(JSONValue.parse(try await minted.text()))).id
      let record = try #require(try await harness.space.execRecord(id))
      #expect(record.caller == "nightly@shared")
      #expect(record.session == nil)
      #expect(record.group == .shared)

      let own = try JSONValueDecoder().decode([ExecStatus].self, from: try #require(JSONValue.parse(try await harness.get("/v1/exec", bearer: firing).text())))
      #expect(own.map(\.id) == [id])
      #expect(try await harness.get("/v1/exec/\(id.rawValue)", bearer: firing).status == .ok)
      let session = try await harness.store.createSession(
        group: .shared, title: "agent", kind: .agent, createdBy: "owner",
        executor: .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")),
      )
      #expect(try await harness.get("/v1/exec/\(id.rawValue)", bearer: tokens.sessionToken(session)).status == .notFound)
      let other = tokens.firingToken(Observer(group: .shared, name: "other", firing: "f2"))
      #expect(try await harness.get("/v1/exec/\(id.rawValue)", bearer: other).status == .notFound)
    }
  }
}
