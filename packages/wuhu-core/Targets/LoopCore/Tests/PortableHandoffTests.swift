import Foundation
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct ReplayHandoffLoopTests {
  @Test func boundaryWriteConflictParksSafelyAndResumeKeepsLooperAlive() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "conflict", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        { request in
          var changed = request.transcript
          let marker = TranscriptItem.bookmark(.init(id: UUID(), timestamp: Date()))
          changed.append(marker)
          try await sessions.append(id, items: [marker], transcript: changed)
          throw ReplayBoundaryRequired(binding: .init(identity: "new", epoch: "route"), budget: .init(maxInput: 100_000, maxOutput: 1000))
        },
        { _ in Fix.reply("resumed") },
      ])
      try await runService(space, makeConfig(inference: { try await script($0) })) { service in
        _ = try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("boundary conflict parked") { try await sessions.record(id).work == .errored }
        #expect(try await sessions.record(id).errorMessage?.contains("transcriptChanged") == true)
        #expect(try await sessions.generationState(id).generation == 0)
        try await service.resume(id)
        try await until("same looper resumed") {
          guard script.count == 2 else { return false }
          return try await sessions.settledWork(id)
        }
      }
    }
  }

  @Test func committedSideEffectsFinishBeforeBoundaryAndAreNotRepeated() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "replay handoff", kind: .agent, createdBy: "morgan", model: .test)
      let newBinding = ReplayBinding(identity: "new-account", epoch: "new-route")
      let script = InferenceScript([
        { _ in
          var reply = Fix.reply("working", calls: [.init(id: "write-once", name: "write", arguments: .object([:]))])
          reply.replayBinding = .init(identity: "old-account", epoch: "old-route")
          reply.message.content.insert(.reasoning(.encrypted(.init(providerID: "openai", model: "m", summary: "safe", opaque: "FOREIGN_REASONING", replayScope: "old"))), at: 0)
          return reply
        },
        { request in
          #expect(request.transcript.pendingToolCallIDs.isEmpty)
          #expect(request.transcript.replayBinding?.identity == "old-account")
          throw ReplayBoundaryRequired(binding: newBinding, budget: .init(maxInput: 100_000, maxOutput: 1000))
        },
        { request in
          #expect(request.transcript.replayBinding == newBinding)
          guard case let .generationHead(head)? = request.transcript.items.first else { throw PortableHandoffError.missingGenerationHead }
          #expect(head.runningWork == ["exec.snapshot"])
          #expect(request.transcript.pendingToolCallIDs.isEmpty)
          #expect(request.transcript.items.contains { if case .toolResult = $0 { return true }; return false })
          let json = String(decoding: try JSONEncoder().encode(request.transcript), as: UTF8.self)
          #expect(!json.contains("FOREIGN_REASONING"))
          var reply = Fix.reply("done")
          reply.replayBinding = newBinding
          return reply
        },
      ])
      let exec = ExecScript { _ in .failure(.init(message: "recorded receipt")) }
      var config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })
      config.runningWork = { _ in ["exec.snapshot"] }
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("do work"), to: id)
        try await until("new account request committed") {
          guard script.count == 3 else { return false }
          return try await sessions.settledWork(id)
        }
      }
      #expect(exec.calls.value.count == 1)
      #expect(try await sessions.generationState(id).generation == 1)
      #expect(try await sessions.transcript(id).replayBinding == newBinding)
    }
  }
}
