import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import protocol GRDB.DatabaseValueConvertible
import JSONValue
@testable import LoopCore
import Scratch
import SessionDomain
import SessionTools
@testable import SpaceCore
import StructuredQueries
import Testing
import WuhuAI
import Wuwei

@Job private struct StrandedFileCall {
  static let kind = ToolCallJob.kind
  static let schema = ToolCallJob.schema
  typealias Message = ToolCallJob.Message
  typealias Params = ToolCallJob.Params

  static func create(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute(CallRow.insert { CallRow(started: true) })
  }

  nonisolated(nonsending) mutating func start() async throws -> Outcome {
    do { try await ctx.sleep(for: .seconds(1000)) } catch is CancellationError {}
    return .notDone
  }
}

@Cell private struct FileCallLaunch {
  mutating func launch(_ params: ToolCallJob.Params) {
    ctx.create(StrandedFileCall.ID("stranded-file"), params: params)
  }
}

@Suite struct FileToolRolloverTests {
  private func call(_ name: String) -> ToolCall {
    return ToolCall(id: "call", name: name, arguments: .object(["path": "machines://mc_test/tmp/file"]))
  }

  private func payload(_ name: String, _ content: String) -> ToolResultPayload {
    switch name {
    case "read": .read(.init(path: "machines://mc_test/tmp/file", revision: .machine("new-version"), content: content))
    case "find": .find(.init(output: content))
    case "grep": .grep(.init(output: content))
    default: preconditionFailure("not a file read")
    }
  }

  @Test(arguments: ["read", "find", "grep"], [false, true])
  func `a rolled read discards late success and repeats the whole effect once`(_ name: String, _ finishesOnCancel: Bool) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("file-effect-roll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let session = try await old.sessions.createSession(group: .shared, title: "files", kind: .agent, createdBy: "owner", model: .test)
      let attempts = Box(0)
      let discarded = Box(false)
      let script = InferenceScript([Fix.replying("reading", calls: [call(name)]), Fix.replying("done")])
      let config = makeConfig(executeTool: { _ in
        let attempt = attempts.withLock { $0 += 1; return $0 }
        if attempt == 1 {
          let bytes = Data("old incomplete bytes".utf8)
          await Latch().wait(unless: { Task.isCancelled })
          discarded.withLock { $0 = true }
          if !finishesOnCancel { throw CancellationError() }
          return payload(name, String(decoding: bytes, as: UTF8.self))
        }
        #expect(attempt == 2)
        return payload(name, "new complete read")
      }, inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)
      first.start()
      try await first.enqueue(item: Fix.message("read"), to: session)
      try await until("the old effect holds materialized bytes") { attempts.value == 1 }
      let turn = try #require(old.worker.cell(SessionCell.ID(session.rawValue)).turn())
      let job = Slot(session: session, generation: turn.generation, position: turn.position, stepTry: 0).call
      #expect(old.worker.job(job).db.rows(CallRow.all).first?.started == true)

      second.start()
      await first.shutdown()
      #expect(discarded.value)
      #expect(old.worker.job(job).db.rows(CallRow.all).first?.answer == nil)
      await time.advance(by: 2)
      try await until("the replacement delivers the complete read") { try await new.sessions.settledWork(session) }
      let results = try await new.sessions.lines(session).filter { $0.role == .toolResult }
      #expect(attempts.value == 2)
      #expect(script.count == 2)
      #expect(results.count == 1)
      #expect(results.first?.text.contains("new complete read") == true)
      #expect(results.first?.text.contains("old incomplete bytes") == false)
      #expect(results.first?.message.toolResult?.isError == false)
      let answer = try #require(new.worker.job(job).db.rows(CallRow.all).first?.answer)
      guard case let .result(result, _) = answer else { throw UnexpectedCall("file answer") }
      #expect(result == payload(name, "new complete read"))
      await second.shutdown()
      try await old.close()
      try await new.close()
    }
  }

  @Test(arguments: ["read", "find", "grep"])
  func `a started unanswered file row hydrates into a fresh effect`(_ name: String) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("file-started-roll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let session = try await old.sessions.createSession(group: .shared, title: "stranded file", kind: .agent, createdBy: "owner", model: .test)
      old.worker.register(.job(StrandedFileCall.self))
      old.worker.register(.cell(FileCallLaunch.self))
      old.worker.start()
      let params = ToolCallJob.Params(session: session, generation: 0, position: 0, call: call(name), yieldBy: nil)
      try await old.worker.call(FileCallLaunch.ID("launch")) { $0.launch(params) }
      let job = ToolCallJob.ID("stranded-file")
      try await until("the started row is durable without an answer") { old.worker.job(job).db.rows(CallRow.all).first?.started == true }
      let attempts = Box(0)
      let config = makeConfig(executeTool: { _ in
        attempts.withLock { $0 += 1 }
        return payload(name, "fresh after hydration")
      })
      new.worker.provide(withEscapedDependencies { dependencies in
        LoopClient(
          space: new,
          scripts: Scripts(),
          tools: ToolExecutor(main: MainConnection(), credential: { _ in throw MainUnavailable() }),
          store: new.sessions,
          config: config,
          sleep: { _ in { throw UnexpectedCall("sleep") } },
          dependencies: dependencies,
          scheduler: new.worker.scheduler,
          handler: { _ in throw UnexpectedCall("handler") },
        )
      })
      new.worker.register(.job(ToolCallJob.self))
      new.worker.start()
      await old.stopWorker()
      await time.advance(by: 2)
      try await until("hydration records the fresh answer") { new.worker.job(job).db.rows(CallRow.all).first?.answer != nil }
      let answer = try #require(new.worker.job(job).db.rows(CallRow.all).first?.answer)
      guard case let .result(result, _) = answer else { throw UnexpectedCall("hydrated file answer") }
      #expect(result == payload(name, "fresh after hydration"))
      #expect(attempts.value == 1)
      let mails = try await new.writer.read { try Data.fetchAll($0, sql: "SELECT payload FROM wuwei_mail WHERE recipient = ?", arguments: [SessionCell.ID(session.rawValue).description]) }
      let values = try mails.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
      #expect(values.filter { $0.object?["called"] != nil }.count == 1)
      #expect(!mails.contains { String(decoding: $0, as: UTF8.self).contains("serverRestarted") })
      try await old.close()
      try await new.close()
    }
  }

  @Test(arguments: [("write", false), ("write", true), ("edit", false), ("edit", true)], ["cancelled", "failure", "success"])
  func `a rolled write or edit preserves known success and reports unknown when unanswered`(_ tool: (String, Bool), _ ending: String) async throws {
    let (name, spacePath) = tool
    let path: JSONValue = .string(spacePath ? "/tmp/file" : "machines://mc_test/tmp/file")
    try await withKernelDeps { time in
      let folder = try ScratchFolder("mutation-effect-roll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let session = try await old.sessions.createSession(group: .shared, title: "mutation", kind: .agent, createdBy: "owner", model: .test)
      let attempts = Box(0)
      let canceled = Box(false)
      let arguments: ToolArguments = switch name {
      case "write": .object(["path": path, "content": "new"])
      case "edit": .object(["path": path, "edits": [["old": "old", "new": "new"]]])
      default: preconditionFailure("not a direct file mutation")
      }
      let mutation = ToolCall(id: "call", name: name, arguments: arguments)
      let script = InferenceScript([Fix.replying("mutating", calls: [mutation]), Fix.replying("done")])
      let config = makeConfig(executeTool: { _ in
        let attempt = attempts.withLock { $0 += 1; return $0 }
        #expect(attempt == 1)
        if attempt == 1 { await Latch().wait(unless: { Task.isCancelled }) }
        canceled.withLock { $0 = true }
        switch ending {
        case "cancelled": throw CancellationError()
        case "failure": return .failure(.init(message: "socket closed before a result", code: "unavailable"))
        default: return .text(.init(output: "known mutation success"))
        }
      }, inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let second = SessionExecution(space: new, loopConfig: config)
      first.start()
      try await first.enqueue(item: Fix.message("mutate"), to: session)
      try await until("the old mutation started") { attempts.value == 1 }
      let turn = try #require(old.worker.cell(SessionCell.ID(session.rawValue)).turn())
      let job = Slot(session: session, generation: turn.generation, position: turn.position, stepTry: 0).call
      #expect(old.worker.job(job).db.rows(CallRow.all).first?.started == true)
      second.start()
      await first.shutdown()
      #expect(canceled.value)
      #expect((old.worker.job(job).db.rows(CallRow.all).first?.answer != nil) == (ending == "success"))
      await time.advance(by: 2)
      try await until("the replacement hears the mutation answer") { try await new.sessions.settledWork(session) }
      let results = try await new.sessions.lines(session).filter { $0.role == .toolResult }
      #expect(attempts.value == 1)
      #expect(script.count == 2)
      #expect(results.count == 1)
      let answer = try #require(new.worker.job(job).db.rows(CallRow.all).first?.answer)
      if ending == "success" {
        let output = "known mutation success"
        #expect(results.first?.text.contains(output) == true)
        #expect(results.first?.message.toolResult?.isError == false)
        guard case let .result(result, _) = answer else { throw UnexpectedCall("known mutation answer") }
        #expect(result == .text(.init(output: output)))
      } else {
        #expect(results.first?.text.contains("outcomeUnknown:") == true)
        #expect(results.first?.text.contains("socket closed") == false)
        guard case let .result(.failure(error), _) = answer else { throw UnexpectedCall("mutation unknown answer") }
        #expect(error.code == "unavailable")
        #expect(error.message.hasPrefix("outcomeUnknown:"))
        #expect(error.message.contains("read the path to see whether it applied before retrying"))
      }
      await second.shutdown()
      try await old.close()
      try await new.close()
    }
  }
}
