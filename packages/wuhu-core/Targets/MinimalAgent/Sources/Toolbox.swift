#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import JSONValue
import OrderedCollections
import Subprocess
import Synchronization
#if canImport(System)
  import System
#else
  import SystemPackage
#endif
import WuhuAI

let outputLimit = 32 << 10

struct Toolbox {
  var directory: URL
  var bashTimeoutSeconds: Int
  /// The session token and any variable carrying a secret the agent masks never reach the shell.
  var scrubbed: [Environment.Key: String?]

  init(directory: URL, bashTimeoutSeconds: Int, secrets: [String]) {
    self.directory = directory
    self.bashTimeoutSeconds = bashTimeoutSeconds
    let environment = ProcessInfo.processInfo.environment
    scrubbed = Dictionary(uniqueKeysWithValues: environment.keys.filter { name in
      name == "WUHU_TOKEN" || secrets.contains { !$0.isEmpty && environment[name]!.contains($0) }
    }.map { (Environment.Key(stringLiteral: $0), String?.none) })
  }

  static let complete = "complete"

  static let definitions: [Tool] = [
    Tool(name: "read", description: "Read a UTF-8 text file. Relative paths resolve against the working directory. Past \(outputLimit) bytes the middle is cut.", parameters: schema(["path": "File path."])),
    Tool(name: "write", description: "Create or replace a file with the given text, creating parent directories.", parameters: schema(["path": "File path.", "content": "The whole new file content."])),
    Tool(name: "bash", description: "Run a bash command in the working directory and wait for it. Returns the exit status and the combined stdout and stderr; past \(outputLimit) bytes the middle is cut. A command still running at the timeout is killed with its process group.", parameters: schema(["command": "The bash command."])),
    Tool(name: complete, description: "Finish the task. Call it exactly once, alone, when the work is done or cannot be done; the result is everything the caller receives.", parameters: schema(["result": "The outcome, for the caller."])),
  ]

  private static func schema(_ fields: KeyValuePairs<String, String>) -> JSONValue {
    var properties: [(String, JSONValue)] = []
    for (name, description) in fields { properties.append((name, ["type": "string", "description": .string(description)])) }
    return ["type": "object", "properties": .object(.init(uniqueKeysWithValues: properties)), "required": .array(fields.map { .string($0.key) }), "additionalProperties": false]
  }

  func run(_ call: ToolCall) async -> ToolResultMessage {
    let arguments = call.arguments.json
    func string(_ name: String) throws(ToolFailure) -> String {
      guard let value = arguments.object?[name]?.stringValue else { throw ToolFailure("\(call.name) needs a string \"\(name)\"") }
      return value
    }
    do throws(ToolFailure) {
      let text = switch call.name {
      case "read": try await read(try string("path"))
      case "write": try await write(try string("path"), try string("content"))
      case "bash": try await bash(try string("command"))
      default: throw ToolFailure("unknown tool \(call.name)")
      }
      return ToolResultMessage(toolCallId: call.id, content: [.text(text)])
    } catch {
      return ToolResultMessage(toolCallId: call.id, content: [.text(error.message)], isError: true)
    }
  }

  private func url(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
  }

  private func read(_ path: String) async throws(ToolFailure) -> String {
    let data: Data
    do { data = try Data(contentsOf: url(path)) } catch { throw ToolFailure("cannot read \(path): \(error)") }
    guard String(validating: data, as: UTF8.self) != nil else { throw ToolFailure("\(path) is not UTF-8 text") }
    var capture = Capture()
    capture.append(data)
    return capture.text
  }

  private func write(_ path: String, _ content: String) async throws(ToolFailure) -> String {
    let target = url(path)
    do {
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: target)
    } catch { throw ToolFailure("cannot write \(path): \(error)") }
    return "wrote \(content.utf8.count) bytes to \(path)"
  }

  private func bash(_ command: String) async throws(ToolFailure) -> String {
    @Dependency(\.continuousClock) var continuousClock
    let clock = continuousClock
    let run = BashRun()
    let timeout = Duration.seconds(bashTimeoutSeconds)
    var options = PlatformOptions()
    options.processGroupID = 0
    let status: TerminationStatus
    do {
      status = try await Subprocess.run(
        .name("bash"),
        arguments: ["-c", command],
        environment: .inherit.updating(scrubbed),
        workingDirectory: FilePath(directory.path),
        platformOptions: options,
        input: .none,
        output: .sequence,
        error: .sequence,
      ) { execution in
        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            guard (try? await clock.sleep(for: timeout)) != nil else { return }
            run.timedOut.store(true, ordering: .relaxed)
            try? execution.send(signal: .kill, toProcessGroup: true)
          }
          await withTaskGroup(of: Void.self) { readers in
            for stream in [execution.standardOutput, execution.standardError] {
              readers.addTask {
                do { for try await buffer in stream { buffer.withUnsafeBytes { bytes in run.capture.withLock { $0.append(bytes) } } } } catch {}
              }
            }
          }
          group.cancelAll()
        }
      }.terminationStatus
    } catch { throw ToolFailure("bash did not start: \(error)") }
    let output = run.capture.withLock { $0.text }
    if run.timedOut.load(ordering: .relaxed) { return "timed out after \(bashTimeoutSeconds)s; killed\n\(output)" }
    return switch status {
    case let .exited(code): "exit \(code)\n\(output)"
    case let .signaled(signal): "killed by signal \(signal)\n\(output)"
    }
  }
}

struct ToolFailure: Error {
  var message: String
  init(_ message: String) { self.message = message }
}

private final class BashRun: Sendable {
  let capture = Mutex(Capture())
  let timedOut = Atomic(false)
}

private struct Capture {
  var head: [UInt8] = []
  var tail: [UInt8] = []
  var omitted = 0

  mutating func append(_ bytes: some Collection<UInt8>) {
    let room = max(outputLimit / 2 - head.count, 0)
    head += bytes.prefix(room)
    tail += bytes.dropFirst(room)
    if tail.count > outputLimit / 2 {
      omitted += tail.count - outputLimit / 2
      tail.removeFirst(tail.count - outputLimit / 2)
    }
  }

  var text: String {
    String(decoding: head, as: UTF8.self) + (omitted > 0 ? "\n[\(omitted) bytes omitted]\n" : "") + String(decoding: tail, as: UTF8.self)
  }
}
