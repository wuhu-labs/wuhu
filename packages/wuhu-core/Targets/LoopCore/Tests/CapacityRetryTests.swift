import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct CapacityRetryTests {
  @Test(arguments: [false, true])
  func backpressureErrorsAfterTwoRetriesWithoutCompaction(forced: Bool) async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "capacity", kind: .agent, createdBy: "morgan", model: .test)
      if forced { try await sessions.requestCommand(sid, .compact(instructions: nil)) }
      let error = InferenceError.capacityExceeded(code: "websocket_backpressure", message: "buffer full", status: 429)
      let script = InferenceScript(Array(repeating: Fix.failing(error), count: 4))
      let compactions = Box(0)
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = [1.0, 2.0].map { $0 * Double.random(in: 0 ... 1, using: &rng) }
      try await runService(sessions, makeConfig(inference: { try await script($0) }, compact: { _ in
        compactions.withLock { $0 += 1 }
        return .init(summary: "must not run")
      })) { service in
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("capacity failure") { script.count == index + 1 }
          try await time.wake("retry", after: delay)
        }
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(script.count == 3)
      #expect(compactions.value == 0)
      #expect(try await sessions.record(sid).errorMessage == String(describing: error))
      #expect(try await sessions.hydrate(sid).transcript.kernel.assistantEntries.isEmpty)
    }
  }

  @Test func mechanicalCompactionCannotResetCapacityRetryBudget() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "capacity compaction", kind: .agent, createdBy: "morgan", model: .test)
      let error = InferenceError.capacityExceeded(code: "websocket_backpressure", message: "buffer full", status: 429)
      let script = InferenceScript([Fix.failing(error), Fix.failing(error), Fix.failing(.contextTooLong), Fix.failing(error), Fix.replying("must not run")])
      let compactions = Box(0)
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = [1.0, 2.0].map { $0 * Double.random(in: 0 ... 1, using: &rng) }
      try await runService(sessions, makeConfig(inference: { try await script($0) }, compact: { _ in
        compactions.withLock { $0 += 1 }
        return .init(summary: "mechanical")
      })) { service in
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("capacity failure") { script.count == index + 1 }
          try await time.wake("retry", after: delay)
        }
        try await until("third capacity failure errors") { try await sessions.record(sid).work == .errored }
      }
      #expect(script.count == 4)
      #expect(compactions.value == 1)
      #expect(try await sessions.record(sid).errorMessage == String(describing: error))
      #expect(try await sessions.hydrate(sid).transcript.kernel.assistantEntries.isEmpty)
    }
  }

  @Test(arguments: ["response_too_large", "websocket_message_too_large"])
  func providerOversizeCompactsOnceThenKeepsCode(code: String) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "capacity size", kind: .agent, createdBy: "morgan", model: .test)
      let error = InferenceError.capacityExceeded(code: code, message: "payload too large", status: 413)
      let script = InferenceScript([Fix.failing(error), Fix.failing(error), Fix.replying("must not run")])
      let compactions = Box(0)
      try await runService(sessions, makeConfig(inference: { try await script($0) }, compact: { _ in
        compactions.withLock { $0 += 1 }
        return .init(summary: "folded")
      })) { service in
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(script.count == 2)
      #expect(compactions.value == 1)
      #expect(try await sessions.record(sid).errorMessage == String(describing: error))
    }
  }
}
