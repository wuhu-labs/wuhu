import DeterministicDependencies
import Foundation
@testable import LoopCore
import enum ModelProviders.ModelPlacementReason
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct SessionModelRouteTests {
  func route(member: String = "primary", reason: ModelPlacementReason = .create) -> SessionModelRoute {
    SessionModelRoute(group: "work", member: member, specifier: .init(provider: "p", model: "m", effort: "high"), bindingFingerprint: "fixture", epoch: member, reason: reason, placedAt: handlerDate, evidence: [])
  }

  @Test func routeSurvivesReopenResumeAndOrdinaryCompaction() async throws {
    let folder = try scratchURL("model-route")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")
    try await withSessionHandlerDeps {
      let space = registerHandlerSessions(try Space.open(file: file))
      let store = space.sessions
      let pin = route()
      let id = try await store.createSession(group: .shared, title: "group", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: pin)
      #expect(try await store.hydrate(id).record.executor == .modelGroup(id: "work", effort: "high"))
      try await store.markInterrupted(id)
      try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.resume() }
      let head = GenerationHead(id: UUID(), timestamp: handlerDate, summary: "summary", snapshot: .init(), runningWork: [])
      _ = try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.rows.writeGeneration(id, head: head) }
      await space.stopWorker()
      let reopened = registerHandlerSessions(try Space.open(file: file))
      #expect(try await reopened.sessions.modelRoute(id) == pin)
      #expect(try await reopened.sessions.establishInferenceModelRoute(id, route: route(member: "other")) == pin)
      try await reopened.sessions.markInterrupted(id)
      let next = route(member: "other", reason: .startOver)
      _ = try await reopened.sessions.restart(id, modelRoute: next)
      #expect(try await reopened.sessions.modelRoute(id) == next)
      #expect(try await reopened.sessions.modelRouteHistory(id) == [pin, next])
      #expect(try await reopened.sessions.record(id).executor == .modelGroup(id: "work", effort: "high"))
      _ = try await reopened.sessions.restart(id, executor: .kernel(.test))
      #expect(try await reopened.sessions.modelRoute(id) == nil)
      #expect(try await reopened.sessions.modelRouteHistory(id) == [pin, next])
      try await reopened.close()
      try await space.close()
    }
  }

  @Test func invalidCreateAndBusyRestartCannotPartiallyCommitRoute() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      await #expect(throws: ExecutorSpecError.self) {
        try await store.createSession(group: .shared, title: "bad", kind: .agent, createdBy: "morgan", executor: .kernel(.test), modelRoute: route())
      }
      #expect(try await space.query("SELECT * FROM sessions", as: .shared(.anonymous)).rows.isEmpty)
      let id = try await store.createSession(group: .shared, title: "good", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: route())
      #expect(try await store.modelRoute(id) == route())
    }
  }
}

extension SessionModelRouteTests {
  @Test func directBindingsAreAdditiveAndHistorySurvivesStartOver() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "direct", kind: .agent, createdBy: "morgan", model: .test)
      #expect(try await store.modelRoute(id) == nil)
      let route = SessionModelRoute(group: nil, member: nil, specifier: .test, bindingFingerprint: "fingerprint", epoch: "epoch", reason: .create, placedAt: handlerDate, evidence: [])
      #expect(try await store.establishInferenceModelRoute(id, route: route) == route)
      await store.noMail(id)
      #expect(try await store.modelRouteHistory(id) == [route])
      #expect(try await space.query("SELECT phase FROM session_model_routes", as: .shared(.anonymous)).rows == [[.text("bound")]])
      _ = try await store.restart(id)
      #expect(try await store.modelRoute(id) == nil)
      #expect(try await store.modelRouteHistory(id) == [route])
    }
  }
}

extension SessionModelRouteTests {
  @Test func groupCreateAndStartOverKeepConcreteRouteWhileIntentRemainsAdditive() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      let first = route()
      let id = try await store.createSession(group: .shared, title: "group", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: first)
      #expect(try await store.modelRoute(id)?.specifier == first.specifier)
      #expect(try await store.record(id).executor == .modelGroup(id: "work", effort: "high"))
      var second = route(member: "secondary", reason: .startOver)
      second.specifier.provider = "other"
      second.epoch = "next"
      _ = try await store.restart(id, modelRoute: second)
      #expect(try await store.modelRoute(id)?.specifier == second.specifier)
      #expect(try await store.record(id).executor == .modelGroup(id: "work", effort: "high"))
      #expect(try await store.modelRouteHistory(id) == [first, second])
      _ = try await store.restart(id, executor: .kernel(.test))
      #expect(try await store.record(id).executor == .kernel(.test))
      #expect(try await store.modelRouteHistory(id) == [first, second])
    }
  }
}
