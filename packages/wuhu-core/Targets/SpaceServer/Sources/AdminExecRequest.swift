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
import Dependencies
import NIOCore

extension SpaceServer {
  /// The enabled server authorizes kernel Unix peer credentials against its fixed deployment UID policy; environment markers only reject early.
  public static func requestAdminExec(folder: URL, rollback: Bool = false) async throws {
    try AdminExecError.requireSupportedPlatform()
    guard (ProcessInfo.processInfo.environment["WUHU_EXEC"] ?? "").isEmpty else { throw AdminExecError.refused("deploymentAdminOnly") }
    guard let canonical = realpath(folder.path, nil) else { throw AdminExecError.refused("disabled") }
    defer { free(canonical) }
    let directory = String(cString: canonical) + "/.admin-exec"
    var state = stat()
    guard lstat(directory, &state) == 0, state.st_mode & S_IFMT == S_IFDIR, state.st_mode & 0o777 == 0o700 else { throw AdminExecError.refused("disabled") }
    let path = try AdminExecSocket.location(folder: directory, uid: UInt32(state.st_uid), create: false)
    let request = AdminExecController.Request(id: UUID(), rollback: rollback)
    // Exec intentionally closes the control connection; query the known request ID rather than resubmitting it.
    let receipt: AdminExecController.Reply?
    do { receipt = try await AdminExecSocket.exchange(path: path, message: .init(id: request.id, rollback: rollback)) }
    catch let error as IOError where error.errnoCode == ENOENT || error.errnoCode == ECONNREFUSED { throw AdminExecError.refused("disabled") }
    catch { receipt = nil }
    if let receipt, receipt.code != "accepted" { throw AdminExecError.refused(receipt.code) }
    @Dependency(\.continuousClock) var clock
    try await waitForAdminExec(path: path, request: request, clock: clock)
  }

  private static func waitForAdminExec<C: Clock<Duration>>(path: String, request: AdminExecController.Request, clock: C) async throws {
    let deadline = clock.now.advanced(by: .seconds(35))
    while clock.now < deadline {
      if let reply = try? await AdminExecSocket.exchange(path: path, message: .init(id: request.id, query: true)), reply.id == request.id, reply.code != "pending" {
        guard reply.code == (request.rollback ? "rolledBack" : "ready") else { throw AdminExecError.refused(reply.code + (reply.reason.map { ":" + $0 } ?? "")) }
        return
      }
      try await clock.sleep(for: .milliseconds(50))
    }
    throw AdminExecError.refused("readinessTimeout")
  }
}
