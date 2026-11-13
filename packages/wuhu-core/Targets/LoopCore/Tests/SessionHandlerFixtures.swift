import ControlledTime
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import SpaceFS

let handlerDate = Date(timeIntervalSince1970: 1_700_000_000)

func withSessionHandlerDeps<T>(_ body: () async throws -> T) async rethrows -> T {
  try await withDependencies {
    $0.uuid = .incrementing
    $0.installTimeControl(anchor: handlerDate)
    $0.withRandomNumberGenerator = .init(SeededRNG(seed: 7))
  } operation: { try await body() }
}

@discardableResult
func registerHandlerSessions(_ space: Space) -> Space {
  _ = SessionExecution(space: space, loopConfig: makeConfig())
  return space
}

func makeHandlerSpace() throws -> Space {
  registerHandlerSessions(try Space.inMemory())
}

extension Space {
  func plantHandlerRows(_ sql: String, arguments: StatementArguments = StatementArguments()) async throws {
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    try await DatabaseQueue(path: writer.path, configuration: configuration).write { try $0.execute(sql: sql, arguments: arguments) }
  }

  func writeHandlerText(_ path: String, _ content: String) async throws {
    _ = try await fs(.shared).write(path, Data(content.utf8), ifMatch: nil)
  }
}
