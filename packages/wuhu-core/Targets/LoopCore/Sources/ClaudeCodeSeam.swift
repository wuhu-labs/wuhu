import ClaudeStream
import Foundation
import SessionDomain

public struct ClaudeCodeLaunch: Sendable {
  public let session: SessionID
  public let activation: UUID
  public let log: ClaudeCodeLog

  init(session: SessionID, activation: UUID, log: ClaudeCodeLog) {
    self.session = session
    self.activation = activation
    self.log = log
  }
}

// One Claude Code process, not yet started: `spawn` only checks what it needs.
// `run` owns everything with a side effect, from the working folder to the
// exit and the cleanup, and says how it ended; `frames` finishes when
// standard output closes. A process never run leaves nothing behind.
public struct ClaudeCodeProcess: Sendable {
  let run: @Sendable () async -> String
  let frames: AsyncStream<ClaudeStreamFrame>
  let write: @Sendable ([UInt8]) async throws -> Void
  let kill: @Sendable () -> Void

  public init(
    run: @escaping @Sendable () async -> String,
    frames: AsyncStream<ClaudeStreamFrame>,
    write: @escaping @Sendable ([UInt8]) async throws -> Void,
    kill: @escaping @Sendable () -> Void,
  ) {
    self.run = run
    self.frames = frames
    self.write = write
    self.kill = kill
  }
}

public enum ClaudeCodeChannel: Hashable, Sendable {
  case standardInput
  case hook
}

public struct ClaudeCodeSeam: Sendable {
  let spawn: @Sendable (ClaudeCodeLaunch) async throws -> ClaudeCodeProcess
  // Only standard input carries image bytes; a hook hands over text alone.
  let render: @Sendable (SessionID, [QueueInput], ClaudeCodeChannel) async throws -> [ClaudeCodeBlock]

  public init(
    spawn: @escaping @Sendable (ClaudeCodeLaunch) async throws -> ClaudeCodeProcess,
    render: @escaping @Sendable (SessionID, [QueueInput], ClaudeCodeChannel) async throws -> [ClaudeCodeBlock],
  ) {
    self.spawn = spawn
    self.render = render
  }

  public static let unavailable: ClaudeCodeSeam = ClaudeCodeSeam(
    spawn: { _ in throw ClaudeCodeUnavailable() },
    render: { _, _, _ in throw ClaudeCodeUnavailable() },
  )
}

struct ClaudeCodeUnavailable: Error, CustomStringConvertible {
  var description: String { "this server runs no Claude Code executor" }
}
