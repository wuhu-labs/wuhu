import JSONValue
import QuickJSKit
import Testing

@Suite struct EvaluationTests {
  @Test func bridgesEveryValueShape() throws {
    let engine = JSEngine()
    #expect(try engine.evaluate("null") == .null)
    #expect(try engine.evaluate("undefined") == .null)
    #expect(try engine.evaluate("true") == .bool(true))
    #expect(try engine.evaluate("1 + 1") == .integer(2))
    #expect(try engine.evaluate("1.5") == .number(1.5))
    #expect(try engine.evaluate("'héllo'") == .string("héllo"))
    #expect(try engine.evaluate("[1, 'a', null, [2]]") == .array([
      .integer(1), .string("a"), .null, .array([.integer(2)]),
    ]))
    #expect(
      try engine.evaluate("({ b: 1, a: { c: true } })")
        == .object(["b": .integer(1), "a": .object(["c": .bool(true)])]),
    )
  }

  @Test func preservesObjectKeyOrder() throws {
    let engine = JSEngine()
    let value = try engine.evaluate("({ z: 1, a: 2, m: 3 })")
    guard case .object(let members) = value else {
      Issue.record("expected an object, got \(value)")
      return
    }
    #expect(Array(members.keys) == ["z", "a", "m"])
  }

  @Test func roundTripsValuesThroughAHostFunction() throws {
    let engine = JSEngine()
    engine.define("echo") { $0[0] }
    let value: JSONValue = .object([
      "n": .null, "b": .bool(false), "i": .integer(-7), "d": .number(0.25),
      "s": .string("λ"), "a": .array([.integer(1), .object(["k": .string("v")])]),
    ])
    engine.define("source") { _ in value }
    #expect(try engine.evaluate("echo(source())") == value)
  }

  @Test func rejectsValuesWithNoJSONShape() throws {
    let engine = JSEngine()
    #expect(throws: JSError.unsupportedValue("function")) {
      try engine.evaluate("(() => 1)")
    }
    #expect(throws: JSError.unsupportedValue("symbol")) {
      try engine.evaluate("Symbol('x')")
    }
    #expect(throws: JSError.unsupportedValue("bigint")) {
      try engine.evaluate("10n")
    }
  }

  @Test func reportsSyntaxAndRuntimeExceptions() throws {
    let engine = JSEngine()
    #expect(throws: JSError.self) { try engine.evaluate("this is not javascript") }
    do {
      _ = try engine.evaluate("function boom() { throw new Error('kaboom') }; boom()")
      Issue.record("expected a thrown exception")
    } catch let error as JSError {
      guard case .exception(let message, let stack) = error else {
        Issue.record("expected an exception, got \(error)")
        return
      }
      #expect(message == "Error: kaboom")
      #expect(stack?.contains("boom") == true)
    }
  }

  @Test func preludeOverridesAGlobalForLaterCode() async throws {
    let engine = JSEngine()
    try engine.execute("Math.random = () => 0.5")
    #expect(try await engine.run("Math.random() + Math.random()") == .number(1.0))
  }

  @Test func keepsGlobalStateAcrossEntries() async throws {
    let engine = JSEngine()
    try engine.execute("globalThis.log = []")
    _ = try await engine.run("log.push('a')")
    _ = try engine.evaluate("log.push('b')")
    engine.define("tail", promising: { _ in .string("c") })
    _ = try await engine.run("log.push(await tail())")
    #expect(try engine.evaluate("log") == .array([.string("a"), .string("b"), .string("c")]))
  }
}
