import protocol Clocks.NonsendingClock
import ControlledTime
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import LoopCore
import SessionTools
import SpaceContract
import SpaceCore
import SpaceTools
import Testing

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func makeContext(clock: any NonsendingClock<Duration> = ContinuousClock()) async throws -> SpaceToolContext {
  try await withDependencies {
    $0.date = .constant(fixedDate)
    $0.continuousClock = clock
  } operation: {
    let space = try Space.inMemory()
    return SpaceToolContext(space: space, principal: .shared(try await space.ensureDevPerson().actor))
  }
}

func withSessionContext(_ body: (SpaceToolContext) async throws -> Void) async throws {
  try await withDependencies {
    $0.installTimeControl(anchor: fixedDate)
  } operation: {
    @Dependency(\.continuousClock) var clock
    let context = try await makeContext(clock: clock)
    let execution = SessionExecution(
      connection: MainConnection(), credential: { _ in throw MainUnavailable() }, space: context.space,
      loopConfig: { _ in
        LoopConfig(
          executeTool: { _ in throw UnexpectedSessionFixtureWork() },
          inference: { _ in throw UnexpectedSessionFixtureWork() },
          budget: { _ in .init(maxInput: 100_000, maxOutput: 1000) },
        )
      },
    )
    do {
      try await body(context)
    } catch {
      await execution.shutdown()
      throw error
    }
    await execution.shutdown()
  }
}

private struct UnexpectedSessionFixtureWork: Error {}

func tool(_ name: String) -> SpaceTool {
  SpaceToolbox.all.first { $0.name == name }!
}

func run(_ name: String, _ input: JSONValue, _ context: SpaceToolContext) async throws -> JSONValue {
  try await tool(name).run(context, input: input)
}

func run<Output: Decodable>(
  _ name: String,
  _ input: JSONValue,
  _ context: SpaceToolContext,
  as output: Output.Type,
) async throws -> Output {
  try JSONValueDecoder().decode(output, from: try await run(name, input, context))
}

func failure(_ name: String, _ input: JSONValue, _ context: SpaceToolContext) async -> ToolRunError? {
  do {
    _ = try await run(name, input, context)
    return nil
  } catch let error as ToolRunError {
    return error
  } catch {
    return nil
  }
}

func seedFile(_ path: String, _ content: String, _ context: SpaceToolContext) async throws -> WriteOutput {
  try await run("write", .object(["path": .string(path), "content": .string(content)]), context, as: WriteOutput.self)
}
