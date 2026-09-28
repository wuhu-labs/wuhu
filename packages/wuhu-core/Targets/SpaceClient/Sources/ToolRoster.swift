import Fetch
import enum SpaceContract.SessionToolExecutor
import struct SpaceContract.ToolRostersOutput

extension SpaceClient {
  public func sessionTools(executor: SessionToolExecutor? = nil) async throws -> ToolRostersOutput {
    try await self.api(
      .get,
      executor.map { "/v1/session-tools?executor=\($0.rawValue)" } ?? "/v1/session-tools",
    )
  }
}
