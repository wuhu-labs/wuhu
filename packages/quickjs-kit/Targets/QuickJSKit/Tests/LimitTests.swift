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
}
