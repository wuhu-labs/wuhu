import Foundation
import PiAI

public struct WuhuAsyncBashToolContext: Sendable {
  public var registry: WuhuAsyncBashRegistry
  public var sessionID: String?
  public var ownerID: String?

  public init(
    registry: WuhuAsyncBashRegistry = .shared,
    sessionID: String? = nil,
    ownerID: String? = nil,
  ) {
    self.registry = registry
    self.sessionID = sessionID
    self.ownerID = ownerID
  }
}

public struct WuhuAsyncBashStarted: Sendable, Hashable {
  public var id: String
  public var pid: Int32
  public var startedAt: Date
  public var stdoutFile: String
  public var stderrFile: String

  public init(
    id: String,
    pid: Int32,
    startedAt: Date,
    stdoutFile: String,
    stderrFile: String,
  ) {
    self.id = id
    self.pid = pid
    self.startedAt = startedAt
    self.stdoutFile = stdoutFile
    self.stderrFile = stderrFile
  }
}

public enum WuhuAsyncTaskState: String, Sendable, Hashable, Codable {
  case running
  case finished
}

public struct WuhuAsyncBashStatus: Sendable, Hashable, Codable {
  public var id: String
  public var state: WuhuAsyncTaskState
  public var pid: Int32?
  public var startedAt: Date
  public var endedAt: Date?
  public var durationSeconds: Double?
  public var exitCode: Int32?
  public var timedOut: Bool
  public var stdoutFile: String
  public var stderrFile: String

  public init(
    id: String,
    state: WuhuAsyncTaskState,
    pid: Int32?,
    startedAt: Date,
    endedAt: Date?,
    durationSeconds: Double?,
    exitCode: Int32?,
    timedOut: Bool,
    stdoutFile: String,
    stderrFile: String,
  ) {
    self.id = id
    self.state = state
    self.pid = pid
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.durationSeconds = durationSeconds
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.stdoutFile = stdoutFile
    self.stderrFile = stderrFile
  }
}

public struct WuhuAsyncBashCompletion: Sendable, Hashable {
  public var id: String
  public var sessionID: String?
  public var ownerID: String?
  public var pid: Int32
  public var startedAt: Date
  public var endedAt: Date
  public var durationSeconds: Double
  public var exitCode: Int32
  public var timedOut: Bool
  public var stdoutFile: String
  public var stderrFile: String
}

public actor WuhuAsyncBashRegistry {
  public static let shared = WuhuAsyncBashRegistry()

  public init() {}

  private final class TaskRecord {
    let id: String
    let sessionID: String?
    let ownerID: String?
    let startedAt: Date
    let stdoutURL: URL
    let stderrURL: URL
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle
    let process: Process
    let timeoutSeconds: Double?

    var endedAt: Date?
    var exitCode: Int32?
    var timedOut: Bool = false

    init(
      id: String,
      sessionID: String?,
      ownerID: String?,
      startedAt: Date,
      stdoutURL: URL,
      stderrURL: URL,
      stdoutHandle: FileHandle,
      stderrHandle: FileHandle,
      process: Process,
      timeoutSeconds: Double?,
      endedAt: Date?,
      exitCode: Int32?,
    ) {
      self.id = id
      self.sessionID = sessionID
      self.ownerID = ownerID
      self.startedAt = startedAt
      self.stdoutURL = stdoutURL
      self.stderrURL = stderrURL
      self.stdoutHandle = stdoutHandle
      self.stderrHandle = stderrHandle
      self.process = process
      self.timeoutSeconds = timeoutSeconds
      self.endedAt = endedAt
      self.exitCode = exitCode
    }
  }

  private var tasks: [String: TaskRecord] = [:]
  private var subscribers: [UUID: AsyncStream<WuhuAsyncBashCompletion>.Continuation] = [:]

  public func subscribeCompletions() -> AsyncStream<WuhuAsyncBashCompletion> {
    AsyncStream(WuhuAsyncBashCompletion.self, bufferingPolicy: .bufferingNewest(4096)) { continuation in
      let token = UUID()
      subscribers[token] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSubscriber(token: token) }
      }
    }
  }

  private func removeSubscriber(token: UUID) {
    subscribers[token] = nil
  }

  public func start(
    command: String,
    cwd: String,
    sessionID: String? = nil,
    ownerID: String? = nil,
    timeoutSeconds: Double? = nil,
  ) throws -> WuhuAsyncBashStarted {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
      throw PiAIError.unsupported("Working directory does not exist: \(cwd)\nCannot execute bash commands.")
    }

    let id = UUID().uuidString.lowercased()
    let startedAt = Date()

    let tmp = FileManager.default.temporaryDirectory
    let stdoutURL = tmp.appendingPathComponent("wuhu-async-bash-\(id)-stdout.log")
    let stderrURL = tmp.appendingPathComponent("wuhu-async-bash-\(id)-stderr.log")

    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    process.terminationHandler = { [weak self] _ in
      Task { await self?.markFinished(id: id) }
    }

    try process.run()

    let record = TaskRecord(
      id: id,
      sessionID: sessionID,
      ownerID: ownerID,
      startedAt: startedAt,
      stdoutURL: stdoutURL,
      stderrURL: stderrURL,
      stdoutHandle: stdoutHandle,
      stderrHandle: stderrHandle,
      process: process,
      timeoutSeconds: timeoutSeconds,
      endedAt: nil,
      exitCode: nil,
    )
    tasks[id] = record

    if let timeoutSeconds, timeoutSeconds > 0 {
      Task { [weak self] in
        let ns = UInt64(timeoutSeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
        await self?.terminateIfRunning(id: id, dueToTimeout: true)
      }
    }

    return .init(
      id: id,
      pid: Int32(process.processIdentifier),
      startedAt: startedAt,
      stdoutFile: stdoutURL.path,
      stderrFile: stderrURL.path,
    )
  }

  public func status(id: String) -> WuhuAsyncBashStatus? {
    guard let record = tasks[id] else { return nil }

    if record.endedAt == nil, !record.process.isRunning {
      // Best-effort: handle cases where termination handler didn't run yet.
      markFinished(id: id)
    }

    let endedAt = record.endedAt
    let durationSeconds = endedAt.map { $0.timeIntervalSince(record.startedAt) }
    let state: WuhuAsyncTaskState = endedAt == nil ? .running : .finished
    let pid: Int32? = (state == .running) ? Int32(record.process.processIdentifier) : nil

    return .init(
      id: record.id,
      state: state,
      pid: pid,
      startedAt: record.startedAt,
      endedAt: endedAt,
      durationSeconds: durationSeconds,
      exitCode: record.exitCode,
      timedOut: record.timedOut,
      stdoutFile: record.stdoutURL.path,
      stderrFile: record.stderrURL.path,
    )
  }

  public func terminateIfRunning(id: String, dueToTimeout: Bool) {
    guard let record = tasks[id] else { return }
    guard record.endedAt == nil, record.process.isRunning else { return }
    if dueToTimeout {
      record.timedOut = true
    }
    record.process.terminate()
  }

  private func markFinished(id: String) {
    guard let record = tasks[id] else { return }
    guard record.endedAt == nil else { return }

    record.endedAt = Date()
    record.exitCode = record.process.terminationStatus

    try? record.stdoutHandle.close()
    try? record.stderrHandle.close()

    let endedAt = record.endedAt ?? Date()
    let completion = WuhuAsyncBashCompletion(
      id: record.id,
      sessionID: record.sessionID,
      ownerID: record.ownerID,
      pid: Int32(record.process.processIdentifier),
      startedAt: record.startedAt,
      endedAt: endedAt,
      durationSeconds: endedAt.timeIntervalSince(record.startedAt),
      exitCode: record.exitCode ?? record.process.terminationStatus,
      timedOut: record.timedOut,
      stdoutFile: record.stdoutURL.path,
      stderrFile: record.stderrURL.path,
    )

    for (_, continuation) in subscribers {
      continuation.yield(completion)
    }
  }
}

func wuhuEncodeToolJSON(_ object: JSONValue) -> String {
  let any = object.toAny()
  guard JSONSerialization.isValidJSONObject(any) else { return "{}" }
  let data = (try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys])) ?? Data()
  let s = String(decoding: data, as: UTF8.self)
  return s.isEmpty ? "{}" : s
}
