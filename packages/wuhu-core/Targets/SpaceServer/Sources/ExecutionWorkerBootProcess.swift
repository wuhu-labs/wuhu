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
import Dependencies
import struct Fetch.FetchClient
import ImageRetention
import WorkerOwner
import WorkerProtocol

struct ExecutionWorkerBootProcess: Sendable {
  let fetch: FetchClient
  let executable: String

  static func inspect(_ manifest: ExecutionWorkerManifest) -> ExecutionWorkerBootFence.Process {
    do { return try processBirthIdentity(manifest.processID) == manifest.birth ? .matching : .differentBirth }
    catch {
      if kill(manifest.processID, 0) != 0, errno == ESRCH { return .absent }
      return .unverified
    }
  }

  func terminate(_ manifest: ExecutionWorkerManifest, directory: String) async -> ExecutionWorkerBootFence.Termination {
    let handle = process_open_handle(manifest.processID)
    defer { if handle >= 0 { _ = close(handle) } }
    #if os(Linux)
      guard handle >= 0 else {
        return Self.gone(manifest) ? .exited : .pidHandleUnavailable
      }
    #endif
    guard case .matching = Self.inspect(manifest) else { return Self.gone(manifest) ? .exited : .unconfirmed }
    for token in [manifest.credentials.successor, manifest.credentials.current].compactMap({ $0 }) {
      let client: WorkerClient
      do { client = try WorkerClient(socket: manifest.workerSocket(directory: directory), token: token, control: fetch, bytes: fetch) }
      catch { return .unconfirmed }
      do {
        _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "parent-fence"))
      } catch {
        await client.close()
        if let failure = error as? WorkerProtocolError, failure.code == .unauthorized { continue }
        return Self.gone(manifest) ? .exited : .unconfirmed
      }
      guard case .matching = Self.inspect(manifest) else {
        await client.close()
        return Self.gone(manifest) ? .exited : .unconfirmed
      }
      let acknowledged: Bool
      do { acknowledged = try await client.call(.init(operation: "execution.shutdown")).boolValue == true }
      catch { acknowledged = false }
      await client.close()
      if Self.gone(manifest) { return .exited }
      #if os(Linux)
        _ = acknowledged
        guard case .matching = Self.inspect(manifest) else { return .unconfirmed }
        return await fenceHandle(handle) ? .exited : .didNotExit
      #else
        return acknowledged ? .acknowledgedWithoutPIDHandle : .unconfirmed
      #endif
    }
    if Self.gone(manifest) { return .exited }
    #if os(Linux)
      let expectedExecutable: String
      if let image = manifest.image {
        let root = URL(fileURLWithPath: directory).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("execution-images").path
        do {
          expectedExecutable = try ImageRetention.transaction(root: root) { store in
            try store.verify(image)
            return try store.imagePath(image)
          }
        } catch { return .unsafeProcessIdentity }
      } else { expectedExecutable = executable }
      guard process_matches_worker(manifest.processID, expectedExecutable) == 1 else { return .unsafeProcessIdentity }
      guard case .matching = Self.inspect(manifest) else { return Self.gone(manifest) ? .exited : .unconfirmed }
      return await fenceHandle(handle) ? .staleCredentialExited : .didNotExit
    #else
      return .unconfirmed
    #endif
  }

  private static func gone(_ manifest: ExecutionWorkerManifest) -> Bool {
    switch inspect(manifest) {
    case .absent, .differentBirth: true
    case .matching, .unverified: false
    }
  }

  #if os(Linux)
    private func fenceHandle(_ handle: Int32) async -> Bool {
      _ = process_signal_handle(handle, SIGTERM)
      if await waitForExit(handle) { return true }
      _ = process_signal_handle(handle, SIGKILL)
      return await waitForExit(handle)
    }

    private func waitForExit(_ handle: Int32) async -> Bool {
      @Dependency(\.continuousClock) var clock
      return await waitForExit(handle, clock: clock)
    }

    private func waitForExit<C: Clock<Duration>>(_ handle: Int32, clock: C) async -> Bool {
      let deadline = clock.now.advanced(by: .seconds(2))
      repeat {
        if process_handle_exited(handle) == 1 { return true }
        do { try await clock.sleep(for: .milliseconds(20)) }
        catch { return false }
      } while clock.now < deadline
      return process_handle_exited(handle) == 1
    }
  #endif
}
