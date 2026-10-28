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
import CExecSupervisor
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError

final class ProcessReceipt {
  let path: String
  private(set) var descriptor: Int32

  init(path: String, process: Int32) throws {
    let descriptor = exec_lock_file(path, 1)
    guard descriptor >= 0 else { throw OperationError(.invalidConfiguration, message: "Process receipt is locked") }
    do { try Self.write(process, descriptor: descriptor) }
    catch { exec_close(descriptor); throw error }
    self.path = path; self.descriptor = descriptor
  }

  deinit { close() }

  static func write(_ process: Int32, descriptor: Int32) throws {
    var birth: UInt64 = 0
    if process != 0, exec_process_birth(process, &birth) != 0 { throw OperationError(.invalidConfiguration, message: "Cannot identify process receipt leader") }
    let bytes = Array("\(process) \(birth)".utf8)
    guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0,
          bytes.withUnsafeBytes({ pwrite(descriptor, $0.baseAddress, $0.count, 0) }) == bytes.count,
          fsync(descriptor) == 0 else { throw OperationError(.invalidConfiguration, message: "Cannot write process receipt") }
  }

  func close() {
    guard descriptor >= 0 else { return }
    _ = unlink(path)
    exec_close(descriptor)
    descriptor = -1
  }

  static func publicationLock(_ directory: String, clock: OperationClock = .continuous) async throws -> Int32 {
    let until = clock.now() + .seconds(2)
    while true {
      let descriptor = exec_lock_file(directory + "/.spawn.lock", 1)
      if descriptor >= 0 { return descriptor }
      guard descriptor == -EWOULDBLOCK || descriptor == -EAGAIN, clock.now() < until else { throw failure([directory + "/.spawn.lock"]) }
      try await clock.sleep(.milliseconds(1))
    }
  }

  static func signal(_ path: String, _ signal: Int32) throws {
    let lock = exec_lock_file(path, 0)
    if lock >= 0 {
      _ = unlink(path)
      exec_close(lock)
      return
    }
    if lock == -ENOENT { return }
    guard lock == -EWOULDBLOCK || lock == -EAGAIN else { throw failure([path]) }
    let bytes = try WorkerDirectory.readFile(path)
    guard let text = String(data: bytes, encoding: .utf8) else { throw failure([path]) }
    let fields = text.split(separator: " ")
    guard fields.count == 2, let pid = Int32(fields[0]), let birth = UInt64(fields[1]), birth > 0,
          pid > 1, pid != getpgrp() else { throw failure([path]) }
    var current: UInt64 = 0
    let lookup = exec_process_birth(pid, &current)
    guard lookup == ESRCH || (lookup == 0 && current == birth) else { throw failure([path]) }
    if killpg(pid, signal) != 0, errno != ESRCH { throw failure([path]) }
  }

  static func failure(_ paths: [String]) -> OperationError {
    OperationError(.supervisorUnavailable, message: "localStopFailed: " + paths.joined(separator: ", "), details: ["paths": .array(paths.map { .string($0) })])
  }
}

extension ExecSupervisor {
  /// The service must already be stopped. Locked receipts name live process groups; an unlocked receipt is stale and removed.
  public static func stopInstalled(operationsDirectory: String) async throws {
    try await stopInstalled(operationsDirectory: operationsDirectory, clock: .continuous)
  }

  static func stopInstalled(operationsDirectory: String, clock: OperationClock) async throws {
    let workers = Rendezvous.machineDirectory(operationsDirectory: operationsDirectory) + "/workers"
    var failures: [String] = []
    for root in [operationsDirectory, workers] {
      var state = stat()
      guard lstat(root, &state) == 0 else {
        if errno != ENOENT { failures.append(root) }
        continue
      }
      guard state.st_mode & S_IFMT == S_IFDIR, state.st_uid == getuid(), state.st_mode & 0o077 == 0 else { failures.append(root); continue }
      let names: [String]
      do { names = try FileManager.default.contentsOfDirectory(atPath: root) }
      catch { failures.append(root); continue }
      for name in names {
        guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
        let directory = root + "/" + name
        guard lstat(directory, &state) == 0, state.st_mode & S_IFMT == S_IFDIR, state.st_uid == getuid(), state.st_mode & 0o077 == 0 else { failures.append(directory); continue }
        let receipt = directory + "/.lock"
        var attempted = directory + "/.spawn.lock"
        var frozen = false
        do {
          let publication = try await ProcessReceipt.publicationLock(directory, clock: clock)
          defer { exec_close(publication) }
          // Freeze the owner before reading its exec receipts so no in-flight start can escape the inventory.
          attempted = receipt
          try ProcessReceipt.signal(receipt, SIGSTOP)
          frozen = true
          let children = try FileManager.default.contentsOfDirectory(atPath: directory)
          for child in children where child.hasPrefix(".exec-") {
            do { try ProcessReceipt.signal(directory + "/" + child, SIGKILL) }
            catch { failures.append(directory + "/" + child) }
          }
          try ProcessReceipt.signal(receipt, SIGKILL)
        } catch {
          failures.append(attempted)
          if frozen { try? ProcessReceipt.signal(receipt, SIGCONT) }
        }
      }
    }
    if !failures.isEmpty { throw ProcessReceipt.failure(failures) }
  }
}
