import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import Fetch
import GRDB
import JSONValue
import SessionDomain
import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

private func stallAlerts(_ space: Space, to parent: SessionID, for request: RequestID) async throws -> Int {
  try await space.writer.read { db in
    try Int.fetchOne(
      db,
      sql: "SELECT COUNT(*) FROM session_queue WHERE session_id = ? AND payload LIKE '%requestStall%' AND payload LIKE ?",
      arguments: [parent.rawValue, "%\(request.rawValue)%"],
    ) ?? 0
  }
}

// A request's stall clock against the real runtimes: what holds it and what
// must not.
@Suite(.deterministicDependencies, .sessionFixtures(timeLimit: .minutes(1))) struct RequestStallRuntimeTests {
  @Test func archiveStopsAnInProcessScriptSoItCannotHoldALaterRequest() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(assembledModels: testModelsJSON)
      let space = harness.space
      let model = SessionExecutor.kernel(.init(provider: "offline", model: "small", effort: "none"))
      let parent = try await harness.store.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "owner", executor: model)
      let task = try await harness.store.createSession(group: .shared, title: "task", kind: .task, parent: parent, createdBy: parent.rawValue, executor: model)
      func taskScripts() async -> Int { await harness.runtime.worker.activity().scripts.values.filter { $0 == task }.count }

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await harness.runtime.run() }
        defer { group.cancelAll() }
        let started = try await callResult(harness, task.rawValue, tool: "run_script", .object([
          "source": .string("result('watching'); await sleep(3_600_000)"),
        ]))
        #expect(resultText(started)?.contains("watching") == true)
        #expect(await taskScripts() == 1)

        // The production firing sees the script as a wait.
        let first = RequestID("stall-before-archive")
        _ = try await harness.store.openRequest(on: task, from: parent, messageID: MessageID(first.rawValue), text: "watch", deadline: nil, stallSeconds: 1)
        try await ContinuousClock().sleep(for: .seconds(3))
        #expect(try await stallAlerts(space, to: parent, for: first) == 0)

        try await harness.runtime.service.archive(task, force: true)
        try await until("archive stops the task's script") { await taskScripts() == 0 }
        try await harness.runtime.service.unarchive(task)

        let second = RequestID("stall-after-unarchive")
        _ = try await harness.store.openRequest(on: task, from: parent, messageID: MessageID(second.rawValue), text: "again", deadline: nil, stallSeconds: 1)
        try await until("the new request's stall alert") { try await stallAlerts(space, to: parent, for: second) == 1 }
      }
    }
  }
}
