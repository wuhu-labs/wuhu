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
import enum JSONValue.JSONValue
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.Verdict
import struct OperationRuntime.OperationCancellation
import struct OperationRuntime.OperationChannels
import protocol OperationRuntime.OperationKind

struct ExecInput: Codable, Sendable {
  struct Credential: Codable, Sendable { let token: String; let spaceURL: String }
  let argv: [String]
  let cwd: String
  let env: [String: String]?
  let secretValues: [String: String]?
  let sessionCredential: Credential?
  let stdin: Bool

  func validate() throws {
    guard !argv.isEmpty, !argv[0].isEmpty, cwd.hasPrefix("/"),
          (argv + [cwd]).allSatisfy({ !$0.utf8.contains(0) }),
          (Array((env ?? [:]).keys) + Array((secretValues ?? [:]).keys)).allSatisfy({ !$0.isEmpty && !$0.contains("=") && !$0.utf8.contains(0) }),
          (Array((env ?? [:]).values) + Array((secretValues ?? [:]).values) + [sessionCredential?.token, sessionCredential?.spaceURL].compactMap { $0 }).allSatisfy({ !$0.utf8.contains(0) })
    else {
      throw OperationError(.invalidInput, message: "exec requires an nonempty executable, absolute cwd and NUL-free argv/environment")
    }
  }

  var environment: [String] {
    var value = ProcessInfo.processInfo.environment
    for key in ["WUHU_IDENTITY", "WUHU_GROUP", "WUHU_EXEC", "WUHU_TOKEN", "WUHU_SPACE_URL"] { value.removeValue(forKey: key) }
    value.merge(env ?? [:], uniquingKeysWith: { _, b in b }); value.merge(secretValues ?? [:], uniquingKeysWith: { _, b in b })
    for key in ["WUHU_EXEC", "WUHU_TOKEN", "WUHU_SPACE_URL"] { value.removeValue(forKey: key) }
    if let credential = sessionCredential { value["WUHU_EXEC"] = "1"; value["WUHU_TOKEN"] = credential.token; value["WUHU_SPACE_URL"] = credential.spaceURL }
    return value.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
  }

  var secrets: [String] { Array((secretValues ?? [:]).values) + [sessionCredential?.token].compactMap { $0 } }
}

struct ExecKind: OperationKind {
  let clock: OperationClock
  init(clock: OperationClock = .continuous) { self.clock = clock }
  let descriptor = ComputerKindSchemas.exec
  func validate(_ input: ExecInput) throws { try input.validate() }
  func run(_ input: ExecInput, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    try input.validate()
    try await cancellation.check()
    var child = exec_child()
    let failure = withCStringArray(input.argv) { argv in
      withCStringArray(input.environment) { environment in
        exec_spawn(argv, environment, input.cwd, &child)
      }
    }
    guard failure == 0 else { throw OperationError(.spawnFailed, details: ["errno": .number(Double(failure))]) }
    var inputFD = child.input
    defer { exec_close(inputFD); exec_close(child.output); exec_close(child.error) }
    var pipes = [OutputPipe(name: "stdout", fd: child.output, secrets: input.secrets), OutputPipe(name: "stderr", fd: child.error, secrets: input.secrets)]
    var pending = Data()
    var inputEnded = !input.stdin
    var stopping: String?
    var escalation: Duration?
    var result: JSONValue?
    var reaped = false
    defer { if !reaped { _ = exec_signal_group(child.pid, SIGKILL); _ = exec_reap(child.pid) } }
    while true {
      if result == nil {
        var tag: Int32 = 0; var value: Int32 = 0
        let observed = exec_observe(child.pid, &tag, &value)
        guard observed >= 0 else { throw OperationError(.kindFailed, message: "waitid failed") }
        if observed == 1 {
          result = ["termination": tag == 0 ? ["tag": "exit", "code": .number(Double(value))] : ["tag": "signal", "signal": .number(Double(value))]]
          for i in pipes.indices { try pipes[i].freeze() }
          try await channels.publish(Verdict(stopping == nil ? .completed : .stopped, result: result, reason: stopping))
          exec_close(inputFD); inputFD = -1; pending = Data()
        }
      }
      if result == nil, stopping == nil {
        stopping = await cancellation.reason()
        if Task.isCancelled { stopping = stopping ?? "shutdown" }
        if stopping != nil { _ = exec_signal_group(child.pid, SIGTERM); escalation = clock.now() + .seconds(5) }
      }
      if let deadline = escalation, clock.now() >= deadline {
        _ = exec_signal_group(child.pid, SIGKILL); escalation = nil
      }
      do {
        if result == nil && stopping == nil && inputFD >= 0 {
          if pending.isEmpty && !inputEnded {
            if let payload = try await channels.availableInput("stdin", upTo: 8192) { pending = payload.data ?? Data() }
            else { inputEnded = true }
          }
          if !pending.isEmpty {
            let written = pending.withUnsafeBytes { exec_write(inputFD, $0.baseAddress, $0.count) }
            if written > 0 { pending.removeFirst(Int(written)) }
            else if written != -EAGAIN && written != -EINTR { exec_close(inputFD); inputFD = -1 }
          }
          if inputEnded && pending.isEmpty { exec_close(inputFD); inputFD = -1 }
        }
        if stopping == nil || result != nil {
          for i in pipes.indices { try await pipes[i].pump(channels) }
        }
      } catch is CancellationError {
        if Task.isCancelled { throw CancellationError() }
        guard await cancellation.reason() != nil else { throw CancellationError() }
      }
      if result != nil && escalation == nil && !reaped { _ = exec_reap(child.pid); reaped = true }
      if let result, reaped, pipes.allSatisfy(\.finished) { return result }
      do { try await clock.sleep(.milliseconds(5)) }
      catch { if result != nil { return result! }; throw error }
    }
  }
}

private struct OutputPipe {
  let name: String
  let fd: Int32
  var masker: SecretMasker
  var boundary: Int?
  var finished = false
  var pending = Data()
  var flushed = false
  init(name: String, fd: Int32, secrets: [String]) { self.name = name; self.fd = fd; masker = SecretMasker(secrets: secrets) }
  mutating func freeze() throws {
    guard !finished else { return }
    let size = exec_pending(fd)
    guard size >= 0 else { throw OperationError(.kindFailed, message: "pipe boundary failed") }
    boundary = Int(size)
  }

  mutating func pump(_ channels: OperationChannels) async throws {
    guard !finished else { return }
    let capacity = try await channels.writableBytes(name)
    guard capacity > 0 else { return }
    if !pending.isEmpty {
      let count = min(capacity, pending.count)
      try await channels.send(.init(data: Data(pending.prefix(count))), to: name)
      pending.removeFirst(count)
      return
    }
    if boundary == 0 {
      if !flushed { pending = Data(masker.flush()); flushed = true }
      if pending.isEmpty { try await channels.finish(name); finished = true }
      return
    }
    var bytes = [UInt8](repeating: 0, count: min(8192, capacity, boundary ?? 8192))
    let count = exec_read(fd, &bytes, bytes.count)
    if count > 0 {
      if boundary != nil { boundary! -= Int(count) }
      pending = Data(masker.mask(Array(bytes.prefix(Int(count)))))
    } else if count == 0 { boundary = 0 }
    else if count != -EAGAIN && count != -EINTR { throw OperationError(.kindFailed, message: "pipe read failed") }
  }
}

func withCStringArray<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
  var pointers = strings.map { strdup($0) } + [nil]
  defer { for pointer in pointers { free(pointer) } }
  return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
