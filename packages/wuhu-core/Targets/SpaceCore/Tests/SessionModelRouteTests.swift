import Foundation
import GRDB
import JSONValue
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct SessionModelRouteTests {
  func route(member: String = "primary", reason: ModelPlacementReason = .create) -> SessionModelRoute {
    SessionModelRoute(group: "work", member: member, specifier: .init(provider: "p", model: "m", effort: "high"), bindingFingerprint: "fixture", epoch: member, reason: reason, placedAt: fixedDate, evidence: [])
  }

  @Test func routeSurvivesReopenResumeAndOrdinaryCompaction() async throws {
    let folder = try scratchURL("model-route")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let store = space.sessions
      let pin = route()
      let id = try await store.createSession(group: .shared, title: "group", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: pin)
      #expect(try await store.hydrate(id).record.executor == .modelGroup(id: "work", effort: "high"))
      try await store.markInterrupted(id)
      try await store.markResumed(id)
      let head = GenerationHead(id: UUID(), timestamp: fixedDate, summary: "summary", snapshot: .init())
      _ = try await store.writeCompaction(id, head: head, kept: nil)
      let reopened = try Space.open(file: file)
      #expect(try await reopened.sessions.modelRoute(id) == pin)
      #expect(try await reopened.sessions.establishModelRoute(id, route: route(member: "other")) == pin)
      try await reopened.sessions.markInterrupted(id)
      let next = route(member: "other", reason: .startOver)
      _ = try await reopened.sessions.restart(id, modelRoute: next)
      #expect(try await reopened.sessions.modelRoute(id) == next)
      #expect(try await reopened.sessions.modelRouteHistory(id) == [pin, next])
      #expect(try await reopened.sessions.record(id).executor == .modelGroup(id: "work", effort: "high"))
      _ = try await reopened.sessions.restart(id, executor: .kernel(.test))
      #expect(try await reopened.sessions.modelRoute(id) == nil)
      #expect(try await reopened.sessions.modelRouteHistory(id) == [pin, next])
    }
  }

  @Test func oldDatabaseAddsRouteTableWithoutBackfillOrChangingExistingSessions() async throws {
    let folder = try scratchURL("old-model-route")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let id = try await space.sessions.createSession(group: .shared, title: "direct", kind: .agent, createdBy: "morgan", model: .test)
      let before = try await space.sessions.hydrate(id)
      try await space.writer.write { db in try db.execute(sql: "DROP TABLE session_model_routes") }
      let reopened = try Space.open(file: file)
      #expect(try await reopened.sessions.modelRoute(id) == nil)
      #expect(try await reopened.sessions.hydrate(id) == before)
      #expect(try await reopened.query("SELECT * FROM session_model_routes").rows.isEmpty)
    }
  }

  @Test func invalidCreateAndBusyRestartCannotPartiallyCommitRoute() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      await #expect(throws: ExecutorSpecError.self) {
        try await store.createSession(group: .shared, title: "bad", kind: .agent, createdBy: "morgan", executor: .kernel(.test), modelRoute: route())
      }
      #expect(try await space.query("SELECT * FROM sessions").rows.isEmpty)
      let id = try await store.createSession(group: .shared, title: "good", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: route())
      _ = try await store.enqueue(id, input: SessionFix.message())
      await #expect(throws: SessionStoreError.busyForRestart(id.rawValue)) { try await store.restart(id, modelRoute: route(member: "other")) }
      #expect(try await store.modelRoute(id) == route())
    }
  }
}

extension SessionModelRouteTests {
  @Test func directBindingsAreAdditiveAndHistorySurvivesStartOver() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "direct", kind: .agent, createdBy: "morgan", model: .test)
      #expect(try await store.modelRoute(id) == nil)
      let route = SessionModelRoute(group: nil, member: nil, specifier: .test, bindingFingerprint: "fingerprint", epoch: "epoch", reason: .create, placedAt: fixedDate, evidence: [])
      #expect(try await store.establishModelRoute(id, route: route) == route)
      #expect(try await store.modelRouteHistory(id) == [route])
      #expect(try await space.query("SELECT phase FROM session_model_routes").rows == [[.text("bound")]])
      _ = try await store.restart(id)
      #expect(try await store.modelRoute(id) == nil)
      #expect(try await store.modelRouteHistory(id) == [route])
    }
  }
}

private func decodeDev114KernelConfig(_ config: String) throws -> ModelSpecifier {
  struct Refused: Error {}
  guard let json = JSONValue.parse(config), var fields = json.object,
        let provider = fields.removeValue(forKey: "provider")?.stringValue,
        let model = fields.removeValue(forKey: "model")?.stringValue,
        let effort = fields.removeValue(forKey: "effort")?.stringValue, fields.isEmpty else { throw Refused() }
  return ModelSpecifier(provider: provider, model: model, effort: effort)
}

extension SessionModelRouteTests {
  @Test func groupCreateAndStartOverKeepFrozenDev114ConfigWhileIntentRemainsAdditive() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let first = route()
      let id = try await store.createSession(group: .shared, title: "group", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: first)
      func stored() async throws -> ModelSpecifier {
        let key = id.rawValue
        let config = try await space.writer.read { db in try String.fetchOne(db, sql: "SELECT executor_config FROM sessions WHERE id = ?", arguments: [key])! }
        return try decodeDev114KernelConfig(config)
      }
      #expect(try await stored() == first.specifier)
      #expect(try await store.record(id).executor == .modelGroup(id: "work", effort: "high"))
      var second = route(member: "secondary", reason: .startOver)
      second.specifier.provider = "other"
      second.epoch = "next"
      _ = try await store.restart(id, modelRoute: second)
      #expect(try await stored() == second.specifier)
      #expect(try await store.record(id).executor == .modelGroup(id: "work", effort: "high"))
      #expect(try await store.modelRouteHistory(id) == [first, second])
      _ = try await store.restart(id, executor: .kernel(.test))
      #expect(try await stored() == .test)
      #expect(try await store.record(id).executor == .kernel(.test))
      #expect(try await store.modelRouteHistory(id) == [first, second])
    }
  }
}

extension SessionModelRouteTests {
  @Test func directTargetChangedByOlderServerRebindsWithoutLosingHistory() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "direct", kind: .agent, createdBy: "morgan", model: .test)
      let old = SessionModelRoute(group: nil, member: nil, specifier: .test, bindingFingerprint: "old", epoch: "old", reason: .create, placedAt: fixedDate, evidence: [])
      _ = try await store.establishModelRoute(id, route: old)
      let target = ModelSpecifier(provider: "other", model: "model", effort: "high")
      let key = id.rawValue
      try await space.writer.write { db in try db.execute(sql: "UPDATE sessions SET executor_config = ? WHERE id = ?", arguments: [SessionExecutor.kernel(target).configJSON, key]) }
      #expect(try await store.modelRoute(id) == nil)
      #expect(try await store.record(id).executor == .kernel(target))
      let new = SessionModelRoute(group: nil, member: nil, specifier: target, bindingFingerprint: "new", epoch: "new", reason: .create, placedAt: fixedDate, evidence: [])
      #expect(try await store.establishModelRoute(id, route: new) == new)
      #expect(try await store.modelRouteHistory(id) == [old, new])
    }
  }
}
