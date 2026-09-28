import Dependencies
import Foundation
import JSONValue
import SpaceContract
import SpaceCore
import SpaceTools
import Testing

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func makeContext() throws -> SpaceToolContext {
  try withDependencies {
    $0.date = .constant(fixedDate)
    $0.continuousClock = ContinuousClock()
  } operation: {
    SpaceToolContext(space: try Space.inMemory(), principal: .shared(.anonymous))
  }
}

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
