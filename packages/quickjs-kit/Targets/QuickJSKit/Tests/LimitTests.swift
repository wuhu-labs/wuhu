import JSONValue
import QuickJSKit
import Testing

@Suite struct LimitTests {
  @Test func terminatesARunawayLoopOnTheStepBudget() throws {
    let engine = JSEngine(limits: JSEngine.Limits(stepBudget: 4))
    #expect(throws: JSError.terminated) { try engine.evaluate("while (true) {}") }
  }

  @Test func terminatesARunawayLoopInsideRun() async throws {
    let engine = JSEngine(limits: JSEngine.Limits(stepBudget: 4))
    await #expect(throws: JSError.terminated) { try await engine.run("while (true) {}") }
  }

  @Test func leavesBoundedWorkAlone() throws {
    let engine = JSEngine(limits: JSEngine.Limits(stepBudget: 1000))
    #expect(try engine.evaluate("let n = 0; for (let i = 0; i < 1000; i++) n += i; n") == .integer(499_500))
  }

  @Test func refreshesTheStepBudgetPerEntry() throws {
    let engine = JSEngine(limits: JSEngine.Limits(stepBudget: 4))
    #expect(throws: JSError.terminated) { try engine.evaluate("while (true) {}") }
    #expect(try engine.evaluate("1 + 1") == .integer(2))
  }

  @Test func terminatesOnAnExternalInterrupt() throws {
    let interrupter = JSEngine.Interrupter()
    let engine = JSEngine(interrupter: interrupter)
    interrupter.interrupt()
    #expect(throws: JSError.terminated) { try engine.evaluate("while (true) {}") }
    interrupter.reset()
    #expect(try engine.evaluate("1 + 1") == .integer(2))
  }

  @Test func enforcesTheMemoryLimit() throws {
    let engine = JSEngine(limits: JSEngine.Limits(memoryBytes: 1 << 20))
    #expect(throws: JSError.self) {
      try engine.evaluate("const a = []; for (;;) a.push(new Array(10000).fill(0))")
    }
  }

  @Test func rejectsCyclicValues() throws {
    let engine = JSEngine()
    #expect(throws: JSError.self) {
      try engine.evaluate("const a = {}; a.self = a; a")
    }
  }

  @Test func isolatedEvaluationHasFreshGlobalsAndRestoresInterrupts() throws {
    let engine = JSEngine(limits: .init(stepBudget: 4))
    try engine.execute("globalThis.secret = 7; Object.prototype.tainted = true")
    #expect(try engine.evaluateIsolated("[typeof secret, Object.prototype.tainted === undefined]") == [.string("undefined"), .bool(true)])
    #expect(throws: JSError.terminated) { try engine.evaluateIsolated("while (true) {}") }
    #expect(try engine.evaluate("secret") == .integer(7))
    #expect(throws: JSError.terminated) { try engine.evaluate("while (true) {}") }
  }

  @Test func isolatedEvaluationSharesTheMemoryLimit() throws {
    let engine = JSEngine(limits: .init(memoryBytes: 4 << 20))
    try engine.execute("globalThis.retained = new ArrayBuffer(2500000)")
    #expect(throws: JSError.self) { try engine.evaluateIsolated("new ArrayBuffer(2500000).byteLength") }
    #expect(try engine.evaluate("retained.byteLength") == .integer(2_500_000))
  }

  @Test func isolatedEvaluationAcceptsOnlyItsOwnModules() throws {
    let engine = JSEngine()
    try engine.defineModule("private", source: "export const value = 99")
    #expect(try engine.evaluateIsolated("answer", modules: [
      (name: "local", source: "globalThis.answer = 42"),
    ]) == .integer(42))
    #expect(throws: JSError.self) {
      try engine.evaluateIsolated("0", modules: [(name: "probe", source: "import {value} from 'private'")])
    }
  }
}
