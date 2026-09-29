#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import JSONValue
import MachineChannel
import SpaceClient
import enum SpaceContract.SessionToolExecutor
import struct SpaceContract.ToolError
import Synchronization

public struct ServeCommand: Equatable, Sendable {
  public var folder: String
  public var host: String
  public var port: Int
  public var origin: String? = nil
  public var dev: Bool
  public var publicRead: Bool = false
  public var devImport: String?
  public var devExport: String?
  public var certificate: String?
  public var privateKey: String?
  public var groupCertificate: String? = nil
  public var groupPrivateKey: String? = nil
  public var webApp: String? = nil
  /// Deprecated options serve accepts and ignores, with a warning.
  public var ignoredOptions: [String] = []
}

public enum UserCommand: Equatable, Sendable {
  case add(folder: String, name: String?, admin: Bool)
  case reset(folder: String, account: String)
  case invite(folder: String, account: String, server: String?, ttl: Int?)
}

public struct CommandRunner: Sendable {
  public var fetch: FetchClient
  public var observeFetch: FetchClient
  public var serve: (@Sendable (ServeCommand) async throws -> Void)?
  public var user: (@Sendable (UserCommand) async throws -> (output: String, note: String?))?
  public var stdin: @Sendable () async throws -> String
  public var stdout: @Sendable (String) async -> Void
  public var stderr: @Sendable (String) async -> Void
  public var stdinIsTerminal: Bool
  public var stdinChunks: @Sendable () -> AsyncStream<[UInt8]>
  public var stdoutBytes: @Sendable ([UInt8]) async -> Void
  public var stderrBytes: @Sendable ([UInt8]) async -> Void
  public var dial: (@Sendable (URL, [(String, String)]) async throws -> any FrameTransport)?
  public var environment: [String: String]
  public var currentDirectory: String
  public var version: String

  public init(
    fetch: FetchClient,
    observeFetch: FetchClient? = nil,
    serve: (@Sendable (ServeCommand) async throws -> Void)? = nil,
    user: (@Sendable (UserCommand) async throws -> (output: String, note: String?))? = nil,
    stdin: @escaping @Sendable () async throws -> String,
    stdout: @escaping @Sendable (String) async -> Void,
    stderr: @escaping @Sendable (String) async -> Void,
    stdinIsTerminal: Bool = true,
    stdinChunks: (@Sendable () -> AsyncStream<[UInt8]>)? = nil,
    stdoutBytes: (@Sendable ([UInt8]) async -> Void)? = nil,
    stderrBytes: (@Sendable ([UInt8]) async -> Void)? = nil,
    dial: (@Sendable (URL, [(String, String)]) async throws -> any FrameTransport)? = nil,
    environment: [String: String],
    currentDirectory: String,
    version: String = "0.0.0-unstamped",
  ) {
    self.fetch = fetch
    self.observeFetch = observeFetch ?? fetch
    self.serve = serve
    self.user = user
    self.stdin = stdin
    self.stdout = stdout
    self.stderr = stderr
    self.stdinIsTerminal = stdinIsTerminal
    self.stdinChunks = stdinChunks ?? Self.wholeStdinChunks(stdin)
    self.stdoutBytes = stdoutBytes ?? { bytes in await stdout(String(decoding: bytes, as: UTF8.self)) }
    self.stderrBytes = stderrBytes ?? { bytes in await stderr(String(decoding: bytes, as: UTF8.self)) }
    self.dial = dial
    self.environment = environment
    self.currentDirectory = currentDirectory
    self.version = version
  }

  public func run(arguments: [String]) async -> Int32 {
    do {
      let invocation = try Invocation.parse(arguments)
      let command = invocation.command
      if case let .help(text) = command {
        await self.stdout(text + "\n")
        return 0
      }
      // Resolved before anything else runs: a session's exec never reaches
      // the wallet or the device keys; the local verbs below open neither.
      let identity = try Identity.resolve(environment: self.environment)
      if case .session = identity {
        _ = try GroupSelection.resolve(flag: invocation.group, environment: self.environment, config: nil)
        if command.isRefusedToSessions {
          throw CLIError(message: sessionRefusal)
        }
      }
      if case let .serve(config) = command {
        guard let serve = self.serve else {
          throw CLIError(message: "serve is not available in this client")
        }
        for option in config.ignoredOptions {
          await self.stderr("\(option) is ignored: content is served on <group>.<host> on the one port; remove it\n")
        }
        await self.stderr(
          "serving \(config.folder) on \(config.host):\(config.port) at \(config.origin ?? "https://localhost:\(config.port)")\n",
        )
        try await serve(config)
        return 0
      }
      if case let .upgrade(upgrade) = command {
        try await UpgradeVerb(runner: self).run(upgrade)
        return 0
      }
      // user verbs are offline folder recovery: no wallet, no pinned space.
      if case let .user(recovery) = command {
        guard let user = self.user else {
          throw CLIError(message: "user is not available in this client")
        }
        let result = try await user(recovery)
        await self.stdout(result.output)
        if let note = result.note { await self.stderr(note) }
        return 0
      }
      if case let .session(credential) = identity {
        return try await self.runAsSession(command, credential: credential)
      }
      var wallet = try Wallet.locate(currentDirectory: self.currentDirectory, environment: self.environment)
      let folderTrust = wallet.directory.appendingPathComponent("trust.json")
      // With cwd = HOME the fallback folder wallet is ~/.wuhu itself, whose
      // trust.json is the live user-level store, not a legacy leftover.
      if FileManager.default.fileExists(atPath: folderTrust.path),
         !Self.isUserTrustDirectory(wallet.directory, environment: self.environment)
      {
        await self.stderr(
          "warning: ignoring \(folderTrust.path); server trust is user-level now (~/.wuhu/trust.json)\n"
            + "re-establish it with: wuhu use <host:port> [--pin] — the folder file can be deleted\n",
        )
      }
      // use and group use repair the wallet's group, so a bad one can't block them.
      let group = try GroupSelection.resolve(
        flag: invocation.group,
        environment: self.environment,
        config: command.rewritesWalletGroup ? nil : wallet.configuredGroup,
      )
      var executor = Executor(runner: self, wallet: &wallet, group: group)
      let code = try await executor.run(command)
      for warning in executor.wallet.drainWarnings() {
        await self.stderr(warning)
      }
      return code
    } catch let error as UsageError {
      await self.stderr(error.message + "\n")
      return 64
    } catch let error as SpaceClient.InvalidSpace {
      await self.stderr("invalid space: \(error.space)\n")
      return 64
    } catch let error as SpaceClient.ToolFailure {
      await self.stderr(rendered(error.error))
      return 1
    } catch let error as SpaceClient.TransportFailure {
      await self.stderr(error.message + "\n")
      return 1
    } catch let error as CLIError {
      await self.stderr(error.message + "\n")
      return 1
    } catch {
      await self.stderr(String(describing: error) + "\n")
      return 1
    }
  }

  private static func isUserTrustDirectory(_ directory: URL, environment: [String: String]) -> Bool {
    guard let user = try? ServerTrust.userConfigDirectory(environment: environment) else { return false }
    return directory.resolvingSymlinksInPath().standardizedFileURL.path
      == user.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func wholeStdinChunks(
    _ stdin: @escaping @Sendable () async throws -> String,
  ) -> @Sendable () -> AsyncStream<[UInt8]> {
    {
      let drained = Mutex(false)
      return AsyncStream(unfolding: {
        let first = drained.withLock { state in
          let was = state
          state = true
          return !was
        }
        guard first, let text = try? await stdin(), !text.isEmpty else { return nil }
        return Array(text.utf8)
      })
    }
  }
}

struct UsageError: Error, CustomStringConvertible {
  let message: String
  var description: String { self.message }
}

struct CLIError: Error, CustomStringConvertible {
  let message: String
  var description: String { self.message }
}

private func rendered(_ error: ToolError) -> String {
  var text = "\(error.code.rawValue): \(error.message)\n"
  if let hint = error.hint {
    text += "hint: \(hint)\n"
  }
  return text
}

enum Command: Equatable {
  case help(String)
  case use(String, pin: Bool, group: String?)
  case trust(String)
  case untrust(String)
  case upgrade(UpgradeCommand)
  case read(path: String, rev: Int?, lines: String?)
  case write(path: String, body: String, force: Bool)
  case cat(path: String)
  case transcribe(file: String, language: String?)
  case transcriber
  case put(path: String, force: Bool)
  case edit(path: String, old: String, new: String, force: Bool)
  case remove(path: String, force: Bool)
  case move(from: String, to: String, replace: Bool)
  case list(path: String, rev: Int?)
  case stat(path: String)
  case grep(pattern: String, path: String?, matchLimit: Int?, entryLimit: Int?, step: String?)
  case find(glob: String, path: String?, matchLimit: Int?, entryLimit: Int?, step: String?)
  case history(path: String)
  case checkout(path: String, rev: Int)
  case query(sql: String)
  case tableCreate(path: String, header: JSONValue)
  case tableAlter(path: String, header: JSONValue)
  case tableMutate(path: String, ops: JSONValue)
  case new(template: String, in: String?)
  case observe(ObserveCommand)
  case serve(ServeCommand)
  case user(UserCommand)
  case userList
  case userHandle(handle: String, displayName: String?)
  case userProfile
  case userRemove(account: String)
  case keyList(account: String?)
  case keyRevoke(pubkey: String)
  case login
  case shareLogin(ttl: Int?)
  case machineAdd(name: String?)
  case machineJoin(server: String, fingerprint: String?, name: String?)
  case machineRun
  case machineList
  case machineName(machine: String, name: String)
  case machineRotate(id: String)
  case machineRevoke(id: String)
  case machineMove(machine: String, group: String)
  case deviceList
  case deviceSet(id: String, name: String?, machine: String?)
  case vaultSet(machine: String, name: String)
  case vaultList(machine: String)
  case vaultRemove(machine: String, name: String)
  case secretSet(name: String)
  case secretList
  case secretRemove(name: String)
  case exec(ExecCommand)
  case ps
  case kill(id: String)
  case skillExport
  case modelsUpdate
  case usage(json: Bool)
  case toolRoster(executor: SessionToolExecutor?, json: Bool)
  case authSet(provider: String)
  case authList
  case authRemove(provider: String)
  case authLogin(provider: String)
  case authLogout(provider: String)
  case send(SendCommand)
  case inbox
  case sessionCreate(SessionCreateCommand)
  case sessionRequest(id: String, message: String, deadline: Double?)
  case sessionAction(SessionActionVerb, id: String)
  case sessionCompact(id: String, instructions: String?)
  case sessionRename(id: String, title: String)
  case sessionTags(id: String, tags: [String])
  case sessionRestart(SessionRestartCommand)
  case sessionLog(id: String, view: SessionLogView)
  case sessionEntry(session: String, ref: String)
  case sessionList
  case groupList
  case groupUse(String?)
  case groupCurrent
  case groupSet(id: String, spaceLayer: Bool)
}

extension String {
  // Swift graphemes make hasSuffix("\n") false for a \r\n-terminated paste;
  // match the terminator cluster itself, and strip exactly one — anything
  // beyond its own line ending must not be silently altered.
  func strippingOneTrailingLineEnding() -> String {
    guard let last = self.last, last == "\n" || last == "\r\n" || last == "\r" else { return self }
    return String(self.dropLast())
  }
}

struct SendCommand: Equatable {
  var session: String
  var text: String
  var wait: Bool
  var timeout: Double?
  var attachments: [String] = []
}

struct SessionCreateCommand: Equatable {
  var kind: String?
  var title: String
  var provider: String?
  var model: String?
  var effort: String?
  var tags: [String]
  var template: String?
  var topLevel: Bool = false
  var homeGroup: String?
}

struct SessionRestartCommand: Equatable {
  var id: String
  var provider: String?
  var model: String?
  var effort: String?
  var message: String?
}

enum SessionActionVerb: String, Equatable {
  case interrupt
  case resume
  case archive
  case unarchive
}

enum SessionLogView: Equatable {
  case conversation(limit: Int?, before: Int?)
  case direct(level: Int, limit: Int?, before: String?)
}

struct ExecCommand: Equatable {
  var cwd: String
  var secrets: [String: String]
  var window: Int?
  var maxOutput: Int?
  var timeout: Double?
  var command: [String]
}

struct ObserveCommand: Equatable {
  var request: ObserveRequest
  var once: Bool
}
