import SessionDomain
import SpaceCore

extension Hub {
  // The answer is recorded in the write that sets the title: a retry of the
  // call answers as the first did and never overwrites a later title.
  nonisolated public func setTitle(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: SetTitleArguments,
  ) async throws -> ToolResultPayload {
    do {
      return try await store.setTitle(session, to: arguments.title, answering: callID)
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }
}
