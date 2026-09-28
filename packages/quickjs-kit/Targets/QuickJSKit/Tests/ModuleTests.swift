import JSONValue
import QuickJSKit
import Synchronization
import Testing

private final class Log: Sendable {
  private let entries = Mutex<[JSONValue]>([])

  var values: [JSONValue] { entries.withLock { $0 } }

  func record(_ arguments: [JSONValue]) -> JSONValue {
    entries.withLock { $0.append(arguments.first ?? .null) }
    return .null
  }
}

private func never() async throws -> JSONValue {
  let (stream, continuation) = AsyncStream<Never>.makeStream()
  for await _ in stream {}
  withExtendedLifetime(continuation) {}
  throw CancellationError()
}

@Suite(.timeLimit(.minutes(1))) struct ModuleTests {
  @Test func importsADefinedModuleAndReadsImportMeta() async throws {
    let engine = JSEngine()
    let log = Log()
    engine.define("report", log.record)
    try engine.defineModule("host:math", source: "export const twice = (x) => x * 2")
    try await engine.run(
      module: """
      import { twice } from "host:math"
      report(twice(import.meta.base))
      """,
      meta: ["base": .integer(21)],
    )
    #expect(log.values == [.integer(42)])
  }

  @Test func anEngineFreedAtAPendingTopLevelAwaitReleasesItsModule() async throws {
    for _ in 0 ..< 200 {
      let engine = JSEngine()
      await #expect(throws: JSError.stalled) {
        try await engine.run(module: "globalThis.held = new Promise(() => {}); await held")
      }
    }
  }

  @Test func refusesAnImportNobodyDefined() async throws {
    let engine = JSEngine()
    do {
      try await engine.run(module: "import { readFile } from 'fs'")
      Issue.record("expected the import to fail")
    } catch let JSError.exception(message, _) {
      #expect(message == "ReferenceError: could not load module 'fs'")
    }
  }

  @Test func releasesWithoutWaitingForACallThatDoesNotKeepItAlive() async throws {
    let engine = JSEngine()
    let log = Log()
    engine.define("report", log.record)
    engine.define("forever", keepsAlive: false, promising: { _ in try await never() })
    try await engine.run(module: "forever().then(() => report('woke'))\nreport('done')")
    #expect(log.values == [.string("done")])
  }

  @Test func cancelRejectsWithTheGivenReasonAndCancelsTheHostCall() async throws {
    let engine = JSEngine()
    let log = Log()
    let host = Log()
    engine.define("report", log.record)
    engine.defineCancel("cancel")
    engine.define("tick", promising: { _ in .null })
    engine.define("block", promising: { _ in
      do {
        return try await never()
      } catch {
        _ = host.record([.string("cancelled")])
        throw error
      }
    })
    try await engine.run(module: """
    const call = block()
    await tick()
    report(cancel(call, new RangeError("stop")))
    report(cancel(call, new RangeError("again")))
    try { await call } catch (error) { report(`${error.name}: ${error.message}`) }
    """)
    #expect(log.values == [.bool(true), .bool(false), .string("RangeError: stop")])
    #expect(host.values == [.string("cancelled")])
  }

  @Test func aTopLevelRejectionEndsTheRunWhileCallsArePending() async throws {
    let engine = JSEngine()
    engine.define("block", promising: { _ in try await never() })
    do {
      try await engine.run(module: "block()\nawait null\nthrow new Error('boom')")
      Issue.record("expected the rejection")
    } catch let JSError.exception(message, stack) {
      #expect(message == "Error: boom", "\(String(describing: stack))")
    }
  }

  @Test func cancellingTheTaskEndsAnIdleRun() async throws {
    let engine = JSEngine()
    engine.define("block", promising: { _ in try await never() })
    let run = Task { try await engine.run(module: "await block()") }
    run.cancel()
    await #expect(throws: CancellationError.self) { try await run.value }
  }
}
