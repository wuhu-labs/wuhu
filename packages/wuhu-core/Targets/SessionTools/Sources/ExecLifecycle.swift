import struct MachineContract.ExecID
import struct MachineContract.ExecStatus
import func MainHub.execHandle
import struct MainHub.ToolProblem
import SessionDomain
import SpaceClient

extension ToolExecutor {
  private func ownExec(_ id: ExecID, session: SessionID) async throws -> ExecStatus? {
    do {
      return try await client(session).api(.get, "/v1/exec/\(id.rawValue)")
    } catch let error as SpaceClient.TransportFailure where error.code == "notFound" { return nil }
    catch let error as SpaceClient.ToolFailure where error.error.code.rawValue == "notFound" { return nil }
  }

  private func killExec(_ id: ExecID, client: SpaceClient) async throws {
    do {
      let _: EmptyExecReply = try await client.api(.post, "/v1/exec/\(id.rawValue)/kill")
    } catch let failure as SpaceClient.ToolFailure where failure.error.code.rawValue == "alreadyEnded" {
      throw ToolProblem("\(execHandle(id)) has already ended", code: "alreadyEnded")
    } catch let failure as SpaceClient.TransportFailure where failure.code == "alreadyEnded" {
      throw ToolProblem("\(execHandle(id)) has already ended", code: "alreadyEnded")
    }
  }

  /// Kills the exec an interrupted call started, if it still runs.
  public func killInterrupted(session: SessionID, callID: ToolCallID) async {
    let client = client(session)
    guard let records: [ExecStatus] = try? await client.api(.get, "/v1/exec"),
          let record = records.first(where: { $0.toolCallID == callID.rawValue && $0.state == .live }) else { return }
    try? await killExec(record.id, client: client)
  }

  /// cancel(exec.…): SIGTERM to the process group, SIGKILL 5 s later.
  func cancelExec(_ session: SessionID, _ id: ExecID) async throws -> ToolResultPayload {
    let handle = execHandle(id)
    guard let record = try await ownExec(id, session: session), record.toolCallID != nil else {
      throw ToolProblem("you have no exec \(handle)", code: "notFound")
    }
    guard record.state == .live else { throw ToolProblem("\(handle) has already ended", code: "alreadyEnded") }
    try await killExec(id, client: client(session))
    return .script(.init(output: "\(handle) was sent SIGTERM to its process group, and gets SIGKILL 5 s later"))
  }
}

private struct EmptyExecReply: Decodable {}
