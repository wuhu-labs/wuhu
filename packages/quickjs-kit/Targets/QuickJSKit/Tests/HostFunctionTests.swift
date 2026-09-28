import JSONValue
import QuickJSKit
import Synchronization
import Testing

private struct Gate: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream<Void>.makeStream()
  }

  func open() { continuation.yield() }

  func wait() async {
    for await _ in stream { return }
  }
}

private struct HostFailure: Error, CustomStringConvertible {
  let description = "the host said no"
}

@Suite struct HostFunctionTests {
  @Test func callsASynchronousHostFunction() async throws {
    let engine = JSEngine()
    engine.define("add") { arguments in
      guard case .integer(let a) = arguments[0], case .integer(let b) = arguments[1] else {
        return .null
      }
      return .integer(a + b)
    }
    #expect(try await engine.run("add(2, 3) * 2") == .integer(10))
  }

  @Test func awaitsAnAsynchronousHostFunction() async throws {
    let engine = JSEngine()
    engine.define("greet", promising: { arguments in
      guard case .string(let name) = arguments[0] else { return .null }
      return .string("hello \(name)")
    })
    let result = try await engine.run(
      """
      const greeting = await greet('world')
      greeting.toUpperCase()
      """,
    )
    #expect(result == .string("HELLO WORLD"))
  }

  @Test func resumesTheScriptAfterEachAwait() async throws {
    let engine = JSEngine()
    engine.define("double", promising: { arguments in
      guard case .integer(let value) = arguments[0] else { return .null }
      return .integer(value * 2)
    })
    let result = try await engine.run(
      """
      let total = 0
      for (let i = 1; i <= 4; i++) total += await double(i)
      total
      """,
    )
    #expect(result == .integer(20))
  }

  @Test(.timeLimit(.minutes(1)))
  func runsConcurrentHostCallsConcurrently() async throws {
    let engine = JSEngine()
    let gate = Gate()
    engine.define("blocked", promising: { _ in
      await gate.wait()
      return .string("blocked")
    })
    engine.define("opener", promising: { _ in
      gate.open()
      return .string("opener")
    })
    let result = try await engine.run("(await Promise.all([blocked(), opener()])).join(',')")
    #expect(result == .string("blocked,opener"))
  }

  @Test func surfacesAHostErrorAsAJSException() async throws {
    let engine = JSEngine()
    engine.define("boom") { _ in throw HostFailure() }
    engine.define("boomLater", promising: { _ in throw HostFailure() })
    let result = try await engine.run(
      """
      const seen = []
      try { boom() } catch (error) { seen.push(error.message) }
      try { await boomLater() } catch (error) { seen.push(error.message) }
      seen
      """,
    )
    #expect(result == .array([.string("the host said no"), .string("the host said no")]))
  }

  @Test func propagatesAnUncaughtHostErrorOutOfRun() async throws {
    let engine = JSEngine()
    engine.define("boomLater", promising: { _ in throw HostFailure() })
    do {
      _ = try await engine.run("await boomLater()")
      Issue.record("expected a rejection")
    } catch let error as JSError {
      guard case .exception(let message, _) = error else {
        Issue.record("expected an exception, got \(error)")
        return
      }
      #expect(message == "Error: the host said no")
    }
  }

  @Test func propagatesAJSRejectionOutOfRun() async throws {
    let engine = JSEngine()
    await #expect(throws: JSError.self) {
      try await engine.run("await Promise.reject(new Error('nope'))")
    }
  }

  @Test func reportsAScriptThatAwaitsNothing() async throws {
    let engine = JSEngine()
    await #expect(throws: JSError.stalled) {
      try await engine.run("await new Promise(() => {})")
    }
  }
}
