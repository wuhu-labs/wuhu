#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct ExecutionWorkerBootRefusal: Error, CustomStringConvertible {
  let workers: [ExecutionWorkerBootFence.UnresolvedWorker]

  var description: String {
    let details = workers.map { worker -> String in
      let identity = if let pid = worker.processID, let birth = worker.birthDiagnostic { "pid=\(pid), birth=\(birth)" } else { "pid=unknown, birth=uninspected" }
      let fix = if worker.processID == nil { "verify no worker, then remove \(worker.directory)" } else { "verify the process identity and stop the matching worker" }
      return "\(identity), runtime=\(worker.directory), reason=\(worker.reason.rawValue), fix=\(fix)"
    }.joined(separator: "; ")
    return "Execution host cannot start while a previous worker is not fenced: \(details). Verify each process identity, stop the matching worker, and reopen the space; never signal a reused PID."
  }
}
