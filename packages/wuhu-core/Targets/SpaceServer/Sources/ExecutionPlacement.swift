#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if !os(Linux)
  import MachO
#endif
import struct WorkerProtocol.WorkerProtocolError

public enum ExecutionPlacement: Sendable, Equatable {
  case inProcess
  case worker(executable: URL)

  public static func worker() throws -> Self {
    let path: String
    #if os(Linux)
      path = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
    #else
      var size: UInt32 = 0
      _ = _NSGetExecutablePath(nil, &size)
      var buffer = [CChar](repeating: 0, count: Int(size))
      guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        throw WorkerProtocolError(.invalidConfiguration, message: "Cannot resolve execution worker executable")
      }
      path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    #endif
    return .worker(executable: URL(fileURLWithPath: path).resolvingSymlinksInPath())
  }

  var executable: String? {
    switch self {
    case .inProcess: nil
    case let .worker(executable): executable.path
    }
  }
}
