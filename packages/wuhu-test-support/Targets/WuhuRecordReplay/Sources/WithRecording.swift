import Dependencies
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// Replay by default; record when `RECORDING` matches `name`. Fixtures live in
// `Recordings/<name>` next to the calling file, or under `RECORDINGS_ROOT`
// when set — a Bazel test runs from runfiles, and a recording has to land in
// the source tree to be committed.
public func withRecording(
  _ name: String,
  matchIgnoringBodyFields: Set<String> = [],
  file: String = #filePath,
  body: () async throws -> Void,
) async throws {
  let envMode = RecordingMode.fromEnvironment
  let mode: RecordingMode = envMode.matches(name) ? envMode : .replay

  let environment = ProcessInfo.processInfo.environment
  let recordingsRoot = if mode.isRecording, let root = environment["RECORDINGS_ROOT"], !root.isEmpty {
    URL(fileURLWithPath: root)
  } else {
    URL(fileURLWithPath: file)
      .deletingLastPathComponent()
      .appendingPathComponent("Recordings")
  }
  let connector: WebSocketConnector
  if mode.isRecording {
    @Dependency(WebSocketConnector.self) var ambientConnector
    connector = ambientConnector
  } else {
    connector = .testValue
  }
  let ctx = RecordingContext(
    name: name,
    mode: mode,
    recordingsRoot: recordingsRoot,
    matchIgnoringBodyFields: matchIgnoringBodyFields,
    webSocketConnector: connector,
  )

  do {
    try await withDependencies {
      $0.fetch = ctx.fetchClient
      $0[WebSocketConnector.self] = ctx.webSocketConnector
    } operation: {
      try await body()
    }

  } catch {
    await ctx.finishSockets()
    throw error
  }
  await ctx.finishSockets()
  try ctx.verifyReplay()

  // Fixtures persist only when the body passed: a failed run must not
  // overwrite a good recording.
  if mode.isRecording {
    try await ctx.flushRecordings()
  }
}
