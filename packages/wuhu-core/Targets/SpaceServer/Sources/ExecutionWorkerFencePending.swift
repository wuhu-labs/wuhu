import struct SessionDomain.SessionID

struct ExecutionWorkerFencePending: Error, CustomStringConvertible {
  let session: SessionID
  var description: String { "executionWorkerFencePending: session \(session.rawValue) remains owned by an unfenced worker; resolve its boot fence and reopen the space" }
}
