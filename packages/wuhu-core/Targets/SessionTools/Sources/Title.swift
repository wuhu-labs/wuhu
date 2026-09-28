import SessionDomain
import SpaceCore

extension ToolExecutor {
  func setTitle(
    _ session: SessionID,
    _ arguments: SetTitleArguments,
  ) async throws -> ToolResultPayload {
    do {
      return .setTitle(.init(title: try await store.setTitle(session, to: arguments.title)))
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }
}
