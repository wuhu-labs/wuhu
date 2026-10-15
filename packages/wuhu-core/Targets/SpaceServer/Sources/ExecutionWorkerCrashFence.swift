#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID

struct ExecutionWorkerCrashLoop: Error, CustomStringConvertible {
  let session: SessionID
  var description: String { "executionWorkerCrashLoop: session \(session.rawValue) lost three execution worker incarnations within ten minutes" }
}
