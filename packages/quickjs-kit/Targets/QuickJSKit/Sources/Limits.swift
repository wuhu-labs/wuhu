extension JSEngine {
  public struct Limits: Sendable {
    public var memoryBytes: Int?
    // QuickJS defaults to a stack budget larger than a Swift concurrency thread
    // stack, so an unbounded recursion would smash the real stack before
    // QuickJS noticed. See SPEC.md.
    public var stackBytes: Int
    public var stepBudget: Int?

    public init(
      memoryBytes: Int? = nil,
      stackBytes: Int = 256 * 1024,
      stepBudget: Int? = nil,
    ) {
      self.memoryBytes = memoryBytes
      self.stackBytes = stackBytes
      self.stepBudget = stepBudget
    }
  }
}
