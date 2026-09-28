import Foundation

// MARK: - Recording Mode

/// Controls whether record/replay tests hit the network or replay fixtures.
enum RecordingMode: Sendable {
  /// Make real HTTP requests and save fixtures.
  case recordAll

  /// Record only tests whose recording name starts with the given prefix.
  /// Non-matching tests replay from existing fixtures.
  case recordOnly(prefix: String)

  /// Replay from recorded fixtures. No network.
  case replay

  /// Whether this mode makes real HTTP requests.
  var isRecording: Bool {
    switch self {
    case .recordAll, .recordOnly:
      return true
    case .replay:
      return false
    }
  }

  /// The recording mode from the environment.
  /// - `.replay` if `RECORDING` is unset.
  /// - `.recordAll` if `RECORDING=1`.
  /// - `.recordOnly(prefix:)` for any other value.
  static var fromEnvironment: Self {
    guard let env = ProcessInfo.processInfo.environment["RECORDING"], !env.isEmpty else {
      return .replay
    }
    if env == "1" {
      return .recordAll
    }
    return .recordOnly(prefix: env)
  }

  /// Whether this mode should record a test with the given recording name.
  func matches(_ name: String) -> Bool {
    switch self {
    case .recordAll:
      return true
    case let .recordOnly(prefix):
      return name.hasPrefix(prefix)
    case .replay:
      return false
    }
  }
}

// MARK: - Record/Replay Error

/// Errors raised by the record/replay machinery. Thrown across the module
/// boundary as `any Error`; no caller distinguishes the cases, so it stays
/// internal — promote to `public` if one ever needs to.
enum RecordReplayError: Error, CustomStringConvertible {
  case noRecordingsFound(String)
  case requestBodyMismatch(expected: String, actual: String)
  case unexpectedStatus(Int, String)

  var description: String {
    switch self {
    case let .noRecordingsFound(name):
      return """
      No recordings found for "\(name)".
      Run with RECORDING=1 to (re)create them.
      """
    case let .requestBodyMismatch(expected, actual):
      return "Request body mismatch.\nExpected: \(expected)\nActual: \(actual)"
    case let .unexpectedStatus(code, body):
      return "Unexpected HTTP status \(code). Body: \(body.prefix(500))"
    }
  }
}
