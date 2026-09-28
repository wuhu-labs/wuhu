import Dependencies
import enum Fetch.FetchError
import enum Fetch.TransportFailureKind
import Foundation
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct RetryTests {
  @Test func `transient failures back off on the exact schedule and remint attempt ids`() async throws {
    try await withKernelDeps(seed: 7) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.transient(status: 503, body: nil)),
        Fix.failing(.rateLimited(retryAt: nil)),
        Fix.failing(.transient(status: nil, body: "flaky")),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      // The same jitter stream the kernel consumes: base 1s, x2, cap 60s,
      // full jitter via the injected generator. createSession's allocation
      // already drew the 32 freeze-secret candidate bytes from it.
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = (0 ..< 3).map { attempt in
        min(backoffCeiling, pow(2.0, Double(attempt))) * Double.random(in: 0 ... 1, using: &rng)
      }

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)

        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.asleep("backoff \(index + 1)", dueIn: delay)
          await time.advance(by: delay * 0.5)
          try await holds("attempt count at \(index + 1) mid-backoff") { script.count == index + 1 }
          await time.advance(by: delay * 0.5)
        }
        try await until("final attempt") { script.count == 4 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let attempts = script.attempts.value
      #expect(attempts.count == 4)
      #expect(Set(attempts.map(\.id)).count == 4)
      #expect(attempts.map(\.mode) == [.normal, .normal, .normal, .normal])

      let expected = delays.reduce(into: [0.0]) { acc, delay in
        acc.append(acc.last! + delay)
      }
      let offsets = attempts.map { $0.at.timeIntervalSince(anchor) }
      for (offset, expectedOffset) in zip(offsets, expected) {
        #expect(abs(offset - expectedOffset) < 0.001)
      }

      // Discarded attempts never touched the transcript: every retry rendered
      // the same item count, and only the successful id was committed.
      #expect(Set(attempts.map(\.itemCount)).count == 1)
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      let entries = transcript.assistantEntries
      #expect(entries.count == 1)
      #expect(entries[0].id == attempts[3].id)
      #expect(!attempts[0 ..< 3].map(\.id).contains(entries[0].id))
    }
  }

  @Test func `terminal inference failure parks the session durably`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.invalidInput(status: 400, body: "bad request")),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }

      let record = try await sessions.record(sid)
      #expect(record.work == .errored)
      #expect(record.errorMessage?.contains("invalidInput") == true)
      #expect(script.count == 1)
    }
  }

  @Test func `completed inference resets the backoff count`() async throws {
    try await withKernelDeps(seed: 21) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.transient(status: 503, body: nil)),
        Fix.failing(.transient(status: 503, body: nil)),
        Fix.replying("first"),
        Fix.failing(.transient(status: 503, body: nil)),
        Fix.replying("second"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      var rng: any RandomNumberGenerator = SeededRNG(seed: 21)
      mirrorAllocationDraws(&rng)
      let jitters = (0 ..< 3).map { _ in Double.random(in: 0 ... 1, using: &rng) }
      // Attempts 1 and 2 fail: raws 1s then 2s. The success resets the count,
      // so the second work item's single failure backs off at 1s again.
      let delays = [1 * jitters[0], 2 * jitters[1], 1 * jitters[2]]

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("attempt 1") { script.count == 1 }
        try await time.wake("backoff 1", after: delays[0])
        try await until("attempt 2") { script.count == 2 }
        try await time.wake("backoff 2", after: delays[1])
        try await until("first success") { script.count == 3 }
        try await until("settled once") { try await sessions.settledWork(sid) }

        _ = try await service.enqueue(item: Fix.message("two"), to: sid)
        try await until("attempt 4") { script.count == 4 }
        try await time.wake("backoff 3", after: delays[2])
        try await until("second success") { script.count == 5 }
        try await until("settled twice") { try await sessions.settledWork(sid) }
      }

      let offsets = script.attempts.value.map { $0.at.timeIntervalSince(anchor) }
      #expect(abs(offsets[1] - (offsets[0] + delays[0])) < 0.001)
      #expect(abs(offsets[2] - (offsets[1] + delays[1])) < 0.001)
      #expect(abs(offsets[4] - (offsets[3] + delays[2])) < 0.001)
    }
  }

  @Test func `consecutive idle timeouts escalate the window and park after the third`() async throws {
    try await withKernelDeps(seed: 7) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.transport(.idleTimeout)),
        Fix.failing(.transport(.idleTimeout)),
        Fix.failing(.transport(.idleTimeout)),
      ])
      let config = makeConfig(inference: { try await script($0) })

      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = (0 ..< 2).map { attempt in
        min(backoffCeiling, pow(2.0, Double(attempt))) * Double.random(in: 0 ... 1, using: &rng)
      }

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("backoff \(index + 1)", after: delay)
        }
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }

      let record = try await sessions.record(sid)
      #expect(record.work == .errored)
      #expect(record.errorMessage?.contains("idleTimeout") == true)
      #expect(script.count == 3)
      #expect(script.attempts.value.map(\.idleTimeout) == [.seconds(120), .seconds(300), .seconds(900)])
    }
  }

  @Test func `a non-timeout outcome resets the idle escalation`() async throws {
    try await withKernelDeps(seed: 7) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.transport(.idleTimeout)),
        Fix.failing(.transient(status: 503, body: nil)),
        Fix.failing(.transport(.idleTimeout)),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = (0 ..< 3).map { attempt in
        min(backoffCeiling, pow(2.0, Double(attempt))) * Double.random(in: 0 ... 1, using: &rng)
      }

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("backoff \(index + 1)", after: delay)
        }
        try await until("final attempt") { script.count == 4 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(script.attempts.value.map(\.idleTimeout) == [
        .seconds(120), .seconds(300), .seconds(120), .seconds(300),
      ])
    }
  }

  // The failure shape that parked gtd's codex sessions: a credential-refresh
  // hop throws Fetch's own error, which never was an InferenceError, so the
  // loop read it as terminal and burned the session on its first blip.
  @Test func `a transport failure raised outside the model call still retries`() async throws {
    try await withKernelDeps(seed: 7) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.throwing(FetchError.transportFailure(kind: .connectTimeout)),
        Fix.throwing(FetchError.transportFailure(kind: .connectionClosed)),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = (0 ..< 2).map { attempt in
        min(backoffCeiling, pow(2.0, Double(attempt))) * Double.random(in: 0 ... 1, using: &rng)
      }

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("backoff \(index + 1)", after: delay)
        }
        try await until("final attempt") { script.count == 3 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(try await sessions.record(sid).work != .errored)
    }
  }

  @Test func `a connect timeout does not spend the idle-timeout budget`() async throws {
    try await withKernelDeps(seed: 7) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.transport(.connectTimeout)),
        Fix.failing(.transport(.connectTimeout)),
        Fix.failing(.transport(.connectTimeout)),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = (0 ..< 3).map { attempt in
        min(backoffCeiling, pow(2.0, Double(attempt))) * Double.random(in: 0 ... 1, using: &rng)
      }

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("backoff \(index + 1)", after: delay)
        }
        try await until("final attempt") { script.count == 4 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(script.attempts.value.allSatisfy { $0.idleTimeout == .seconds(120) })
    }
  }

  @Test func `consecutive unretryable failures park at the bounded limit`() async throws {
    try await withKernelDeps(seed: 7) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript(
        Array(repeating: Fix.failing(.transient(status: 503, body: "upstream down")), count: 9),
      )
      let config = makeConfig(inference: { try await script($0) })

      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = (0 ..< boundedFailureLimit - 1).map { attempt in
        min(backoffCeiling, pow(2.0, Double(attempt))) * Double.random(in: 0 ... 1, using: &rng)
      }

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("backoff \(index + 1)", after: delay)
        }
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }

      let record = try await sessions.record(sid)
      #expect(record.work == .errored)
      #expect(record.errorMessage?.contains("upstream down") == true)
      #expect(script.count == boundedFailureLimit)
    }
  }

  // The overnight case: the provider is down for hours and comes back on its
  // own. No attempt count survives that, so throttling and unreachability are
  // bounded by rate instead — the session waits it out and nobody is woken.
  @Test func `throttling and unreachable networks retry past the bounded limit`() async throws {
    for outage in [InferenceError.rateLimited(retryAt: nil), .transport(.connectionClosed)] {
      try await withKernelDeps(seed: 7) { time in
        let sessions = try Space.inMemory().sessions
        let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

        let rounds = boundedFailureLimit * 2
        let script = InferenceScript(
          Array(repeating: Fix.failing(outage), count: rounds) + [Fix.replying("back online")],
        )
        let config = makeConfig(inference: { try await script($0) })

        var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
        mirrorAllocationDraws(&rng)
        let delays = (0 ..< rounds).map { attempt in
          min(backoffCeiling, pow(2.0, Double(attempt))) * Double.random(in: 0 ... 1, using: &rng)
        }

        try await runService(sessions, config) { service in
          _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
          for (index, delay) in delays.enumerated() {
            try await until("\(outage) attempt \(index + 1)") { script.count == index + 1 }
            try await time.wake("backoff \(index + 1)", after: delay)
          }
          try await until("\(outage) recovered") { script.count == rounds + 1 }
          try await until("settled") { try await sessions.settledWork(sid) }
        }

        #expect(try await sessions.record(sid).work != .errored)
      }
    }
  }

  // An outage does not spend the budget that exists for failures which will
  // not fix themselves; a session may ride out a long one and still report
  // promptly on a fault that follows it.
  @Test func `an outage does not spend the bounded-failure budget`() async throws {
    try await withKernelDeps(seed: 7) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let leading = Array(repeating: Fix.failing(.rateLimited(retryAt: nil)), count: boundedFailureLimit)
      let script = InferenceScript(
        leading + Array(repeating: Fix.failing(.transient(status: 503, body: "still bad")), count: boundedFailureLimit),
      )
      let config = makeConfig(inference: { try await script($0) })

      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = (0 ..< (2 * boundedFailureLimit - 1)).map { attempt in
        min(backoffCeiling, pow(2.0, Double(attempt))) * Double.random(in: 0 ... 1, using: &rng)
      }

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("backoff \(index + 1)", after: delay)
        }
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }

      // Eight throttles then eight 503s: the throttles cost the bounded budget
      // nothing, so the park lands on the sixteenth attempt, not the ninth.
      #expect(script.count == 2 * boundedFailureLimit)
      #expect(try await sessions.record(sid).errorMessage?.contains("still bad") == true)
    }
  }
}
