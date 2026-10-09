#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import protocol MachineChannel.FrameTransport
import enum MachineContract.SessionExecEnvironment
import SpaceClient

let sessionRefusal = "not available to a session; set WUHU_IDENTITY=wallet to act as the wallet's owner"

// What a session's exec was handed by the server that started it: the bearer
// that acts as that session, and the one space it acts on.
struct SessionCredential: Equatable, Sendable {
  var token: String
  var space: String
}

enum Identity: Equatable {
  case wallet(announce: Bool)
  case session(SessionCredential)

  static func resolve(environment: [String: String]) throws -> Self {
    guard isSessionExec(environment) else { return .wallet(announce: false) }
    switch environment[SessionExecEnvironment.identity] {
    case nil, "", "session":
      break
    case "wallet":
      return .wallet(announce: true)
    case let other?:
      throw UsageError(message: "WUHU_IDENTITY is session or wallet, not \(other)")
    }
    guard let token = environment[SessionExecEnvironment.token], !token.isEmpty else {
      throw CLIError(message: """
      this exec runs for a session (WUHU_EXEC=1) but WUHU_TOKEN is unset, so it cannot act as the session; \
      the wallet is not used in its place
      """)
    }
    guard let space = environment[SessionExecEnvironment.spaceURL],
          let url = URL(string: space), url.scheme == "https" || url.scheme == "http", url.host != nil
    else {
      throw CLIError(message: """
      this exec runs for a session (WUHU_EXEC=1) but WUHU_SPACE_URL is unset or not a URL, so it cannot act \
      as the session; the wallet is not used in its place
      """)
    }
    return .session(SessionCredential(token: token, space: space))
  }
}

/// Any non-empty `WUHU_EXEC` marks a session's exec, whatever its value.
func isSessionExec(_ environment: [String: String]) -> Bool {
  !(environment[SessionExecEnvironment.exec] ?? "").isEmpty
}

extension Command {
  var runsWithoutWallet: Bool {
    switch self {
    case .serve, .upgrade, .user: true
    default: false
    }
  }

  // Verbs that act on the wallet, the device keys or the wallet's owner
  // rather than on the session's space. The server refuses every other verb a
  // session lacks; these never reach it (models update would otherwise write
  // /models.json through a tool a session may call). serve and user open
  // none of those, so an exec runs them; upgrade may only check, since on a
  // server's host it swaps the binary the server runs.
  var isRefusedToSessions: Bool {
    switch self {
    case let .upgrade(upgrade):
      !upgrade.check
    case .use, .trust, .untrust, .userList, .userHandle, .userProfile, .userRemove,
         .keyList, .keyRevoke, .login, .shareLogin, .machineAdd, .machineJoin, .machineRun, .machineRotate,
         .machineRevoke, .machineMove, .authSet, .authList, .authRemove, .authLogin,
         .authLogout, .modelsUpdate, .groupUse, .identitySet, .identityRotate, .identityRegisterNew:
      true
    default:
      false
    }
  }
}

extension CommandRunner {
  // A session's exec never reads the wallet or the device keys: its state (the
  // read-before-write tokens, observe cursors) lives in a scratch folder keyed
  // by its token.
  func runAsSession(_ command: Command, credential: SessionCredential) async throws -> Int32 {
    var wallet = Wallet(sessionState: self.sessionStateDirectory(credential), space: credential.space)
    var executor = Executor(runner: self, wallet: &wallet, session: credential)
    let code = try await executor.run(command)
    for warning in executor.wallet.drainWarnings() {
      await self.stderr(warning)
    }
    return code
  }

  // The TMPDIR in the exec's environment, which Darwin's Foundation would ignore.
  func sessionStateDirectory(_ credential: SessionCredential) -> URL {
    let tmp = self.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
    return (tmp ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("wuhu-exec-" + SHA256.hex(credential.token).prefix(24), isDirectory: true)
  }
}

extension Executor {
  // A session acts on its own space only: an explicit address of another
  // server is refused rather than silently redirected.
  func scoped(_ space: String) throws -> String {
    guard let session = self.session else { return space }
    guard sameServer(space, session.space) else {
      throw CLIError(message: """
      \(space) is not this session's space (\(session.space)); \(sessionRefusal)
      """)
    }
    return session.space
  }

  func sessionClient(_ session: SessionCredential, longRunning: Bool = false) -> SpaceClient {
    let runner = self.runner
    let bearer = "Bearer " + session.token
    var dial: (@Sendable (URL, [(String, String)]) async throws -> any FrameTransport)?
    if let inner = runner.dial {
      dial = { url, headers in
        try await inner(url, headers + [("authorization", bearer)])
      }
    }
    return SpaceClient(
      space: session.space,
      fetch: bearing(longRunning ? runner.observeFetch : runner.fetch, bearer),
      observeFetch: bearing(runner.observeFetch, bearer),
      dial: dial,
    )
  }
}

func sameServer(_ a: String, _ b: String) -> Bool {
  func key(_ raw: String) -> String? {
    let spelled = raw.contains("://") ? raw : "https://" + raw
    return URL(string: spelled).flatMap(ServerTrust.hostKey(url:))?.lowercased()
  }
  guard let a = key(a), let b = key(b) else { return false }
  return a == b
}

private func bearing(_ fetch: FetchClient, _ bearer: String) -> FetchClient {
  FetchClient { request in
    var request = request
    request.headers.setSensitive(.authorization, bearer)
    return try await fetch(request)
  }
}
