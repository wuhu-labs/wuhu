#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

private let malformed = InferenceError.malformedModelMessage(message: "Malformed tool_use", reason: "name_charset")

@Suite struct MixedMalformedMessageRetryTests {
  @Test(arguments: [false, true])
  func mechanicalCompactionDoesNotResetBudget(transientPark: Bool) async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "mixed compaction", kind: .agent, createdBy: "morgan", model: .test)
      if transientPark { try await sessions.requestCommand(sid, .compact(instructions: nil)) }
      let middle: [InferenceScript.Step] = transientPark
        ? Array(repeating: Fix.failing(.transient(status: 503, body: "unretryable")), count: boundedFailureLimit)
        : [Fix.failing(.contextTooLong)]
      let script = InferenceScript([Fix.failing(malformed), Fix.failing(malformed)] + middle + [Fix.failing(malformed), Fix.replying("must not run")])
      let compactions = Box(0)
      let config = makeConfig(inference: { try await script($0) }, compact: { _ in
        compactions.withLock { $0 += 1 }
        return .init(summary: "mechanical, not successful inference")
      })
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let backoffs = transientPark ? boundedFailureLimit + 1 : 2
      let delays = (0 ..< backoffs).map { pow(2.0, Double($0)) * Double.random(in: 0 ... 1, using: &rng) }
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("retry \(index + 1)", after: delay)
        }
        try await until("errored after compaction") { try await sessions.record(sid).work == .errored }
      }
      #expect(script.count == middle.count + 3)
      #expect(compactions.value == 1)
      #expect(try await sessions.record(sid).errorMessage == String(describing: malformed))
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.assistantEntries.isEmpty)
      #expect(transcript.items.contains { if case .generationHead = $0 { true } else { false } })
      #expect(script.attempts.value.last?.mode == .normal)
      if transientPark { #expect(script.attempts.value.dropLast().allSatisfy { $0.mode == .forcedCompact }) }
    }
  }

  @Test(arguments: [false, true])
  func transientFailuresKeepMalformedBudgetButMalformedResetsOtherBudgets(idleTimeout: Bool) async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "mixed transient", kind: .agent, createdBy: "morgan", model: .test)
      let leadingCount = idleTimeout ? 2 : boundedFailureLimit - 1
      let error: InferenceError = idleTimeout ? .transport(.idleTimeout) : .transient(status: 503, body: "transient")
      let round = Array(repeating: Fix.failing(error), count: leadingCount) + [Fix.failing(malformed)]
      let script = InferenceScript(round + round + round + [Fix.replying("must not run")])
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let attempts = (leadingCount + 1) * 3
      let delays = (0 ..< attempts - 1).map { min(backoffCeiling, pow(2.0, Double($0))) * Double.random(in: 0 ... 1, using: &rng) }
      try await runService(sessions, makeConfig(inference: { try await script($0) })) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("retry \(index + 1)", after: delay)
        }
        try await until("third malformed errors") { try await sessions.record(sid).work == .errored }
      }
      #expect(script.count == attempts)
      #expect(try await sessions.record(sid).errorMessage == String(describing: malformed))
      #expect(try await sessions.hydrate(sid).transcript.kernel.assistantEntries.isEmpty)
      if idleTimeout {
        #expect(script.attempts.value.map(\.idleTimeout) == Array(repeating: [Duration.seconds(120), .seconds(300), .seconds(900)], count: 3).flatMap { $0 })
      }
    }
  }
}
