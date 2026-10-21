#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import func MainHub.serveWorkerLine
import protocol MainHub.Worker
import let MainHub.workerHoldingHeader
import let MainHub.workerLinePath
import class MainHub.WorkerNotices
import SessionDomain

extension MainConnection {
  /// Opens the worker's line to main, announcing it as holding `holding`,
  /// answers main's calls on it with `worker` and sends it `notices` until
  /// the line closes.
  public func serveLine(_ worker: any Worker, credential: String, holding: [SessionID] = [], notices: WorkerNotices? = nil) async throws {
    guard let url = URL(string: "http://main" + workerLinePath) else { preconditionFailure("the worker line is a path") }
    var headers = [("authorization", "Bearer " + credential)]
    if !holding.isEmpty { headers.append((workerHoldingHeader, holding.map(\.rawValue).joined(separator: ","))) }
    let transport = try await dial(url, headers: headers)
    await withTaskCancellationHandler {
      await serveWorkerLine(worker, on: transport, notices: notices)
    } onCancel: {
      transport.close()
    }
  }
}
