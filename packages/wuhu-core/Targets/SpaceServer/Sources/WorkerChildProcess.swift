#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import CProcessIdentity
import struct WorkerProtocol.WorkerProtocolError

enum WorkerChildProcess {
  static func spawn(executable: String, arguments: [String], lease: Int32?) throws -> (processID: Int32, input: Int32) {
    let pointers = ([executable] + arguments).map { strdup($0) }
    defer { for pointer in pointers { free(pointer) } }
    guard pointers.allSatisfy({ $0 != nil }) else { throw failure() }
    var argv = pointers + [nil]
    var processID: Int32 = 0
    var input: Int32 = -1
    let result = executable.withCString { path in
      argv.withUnsafeMutableBufferPointer { process_spawn_worker(path, $0.baseAddress!, lease ?? -1, &processID, &input) }
    }
    guard result == 0 else { throw failure() }
    return (processID, input)
  }

  static func run(executable: String, lease: Int32?, bootstrap: Data, prepare: @Sendable (Int32) async throws -> Void) async throws {
    let child = try spawn(executable: executable, arguments: ["_execution-worker"], lease: lease)
    let birth: String
    do { birth = try processBirthIdentity(child.processID) }
    catch {
      _ = close(child.input)
      await WorkerConnection.waitForExecChild(processID: child.processID, birth: nil, terminate: true)
      throw error
    }
    do {
      try Task.checkCancellation()
      try await prepare(child.processID)
      try Task.checkCancellation()
      try send(bootstrap, input: child.input)
    } catch {
      _ = close(child.input)
      await WorkerConnection.waitForExecChild(processID: child.processID, birth: birth, terminate: true)
      throw error
    }
    _ = close(child.input)
    await WorkerConnection.waitForExecChild(processID: child.processID, birth: birth)
  }

  private static func send(_ bootstrap: Data, input: Int32) throws {
    guard bootstrap.count <= 16 << 10 else { throw failure() }
    try bootstrap.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        #if os(Linux)
          let count = Glibc.send(input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
        #else
          let count = Darwin.send(input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
        #endif
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw failure() }
        offset += count
      }
    }
  }

  private static func failure() -> WorkerProtocolError { .init(.unavailable, message: "Execution worker launch failed") }
}
