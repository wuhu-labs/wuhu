import AsyncHTTPClient
import CLIKit
import struct Fetch.FetchClient
import struct Fetch.Response
import FetchAsyncHTTPClient
import Foundation
import Synchronization

extension UpgradeEnvironment {
  static var live: UpgradeEnvironment {
    UpgradeEnvironment(
      // Redirects stay disabled: the verb follows them itself so Authorization
      // never leaks to the pre-signed storage host (which rejects it).
      fetch: FetchClient { request in
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        do {
          let response = try await FetchClient.asyncHTTPClient(client, timeout: .minutes(10))(request)
          let data = try await response.data(upTo: 1 << 30)
          try await client.shutdown()
          return Response(status: response.status, headers: response.headers, body: .bytes(data))
        } catch {
          try? await client.shutdown()
          throw error
        }
      },
      extract: { archive, destination in
        #if os(macOS)
          _ = try await capturedProcessOutput(["/usr/bin/ditto", "-x", "-k", archive.path, destination.path])
        #else
          _ = try await capturedProcessOutput(["/usr/bin/env", "tar", "-xzf", archive.path, "-C", destination.path])
        #endif
      },
    )
  }
}

private struct ProcessFailure: Error, CustomStringConvertible {
  var command: [String]
  var status: Int32
  var stderr: String

  var description: String {
    "\(self.command.joined(separator: " ")) exited \(self.status): \(self.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
  }
}

// Draining while the child runs keeps a chatty process from blocking on a
// full pipe and never reaching the termination handler.
private final class DrainedPipe: Sendable {
  private let buffer = Mutex(Data())

  init(_ pipe: Pipe) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        self.buffer.withLock { $0.append(data) }
      }
    }
  }

  func settle(_ pipe: Pipe) -> String {
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    return self.buffer.withLock { String(decoding: $0 + tail, as: UTF8.self) }
  }
}

private func capturedProcessOutput(_ command: [String]) async throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: command[0])
  process.arguments = Array(command.dropFirst())
  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  process.standardInput = FileHandle.nullDevice
  let stdoutBuffer = DrainedPipe(stdout)
  let stderrBuffer = DrainedPipe(stderr)
  return try await withCheckedThrowingContinuation { continuation in
    process.terminationHandler = { process in
      let output = stdoutBuffer.settle(stdout)
      let errors = stderrBuffer.settle(stderr)
      if process.terminationStatus == 0 {
        continuation.resume(returning: output)
      } else {
        continuation.resume(throwing: ProcessFailure(command: command, status: process.terminationStatus, stderr: errors))
      }
    }
    do {
      try process.run()
    } catch {
      process.terminationHandler = nil
      continuation.resume(throwing: error)
    }
  }
}
