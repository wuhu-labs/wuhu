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
import Crypto
import struct WorkerProtocol.WorkerProtocolError

struct ExecutionWorkerSocketLocation: Codable, Equatable, Sendable {
  let root: String
  let key: String

  var directory: String { root + "/" + key }
  var worker: String { directory + "/worker.sock" }
  var parent: String { directory + "/parent.sock" }

  static var runtimeRoot: String { selectRoot(environment: ProcessInfo.processInfo.environment) }

  static func selectRoot(environment: [String: String], parentState: (String) -> stat? = inspectParent) -> String {
    #if os(Linux)
      if let xdg = environment["XDG_RUNTIME_DIR"], validPath(xdg),
         (xdg + "/wuhu/" + String(repeating: "0", count: 16) + "/parent.sock").utf8.count < 104,
         let state = parentState(xdg), state.st_mode & S_IFMT == S_IFDIR,
         state.st_uid == geteuid(), state.st_mode & 0o7777 == 0o700
      { return xdg + "/wuhu" }
      return "/tmp/wuhu-" + String(geteuid())
    #else
      return "/private/tmp/wuhu-" + String(geteuid())
    #endif
  }

  private static func inspectParent(_ path: String) -> stat? {
    guard let descriptor = try? ExecutionWorkerManifestStore.openDirectory(path, requirePrivate: false) else { return nil }
    defer { _ = close(descriptor) }
    var state = stat()
    return fstat(descriptor, &state) == 0 ? state : nil
  }

  init(space: String, generation: UUID, root: String = Self.runtimeRoot) {
    self.root = root
    let identity = String(space.utf8.count) + ":" + space + ":" + generation.uuidString.lowercased()
    key = SHA256.hash(data: Data(identity.utf8)).prefix(8).map { ("0" + String($0, radix: 16)).suffix(2) }.joined()
  }

  func validate(space: String, generation: UUID, runtimeRoot: String) throws {
    guard Self.validPath(root), root == runtimeRoot,
          self == Self(space: space, generation: generation, root: root),
          worker.utf8.count < 104, parent.utf8.count < 104
    else { throw WorkerProtocolError(.invalidConfiguration, message: "Invalid execution worker socket location") }
  }

  private static func validPath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.utf8.contains(0) && path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}
