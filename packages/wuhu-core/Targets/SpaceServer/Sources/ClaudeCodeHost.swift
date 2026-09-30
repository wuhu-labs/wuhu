#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif
import class ClaudeInstall.ClaudeCodeInstallation
import struct ClaudeInstall.ClaudeInstallEnvironment
import struct ClaudeInstall.ClaudeInstaller
import ClaudeStream
import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import struct InferenceKit.ModelsDocument
import struct InferenceKit.ProviderCatalog
import Logging
import LoopCore
import Serve
import SessionDomain
import SpaceCore
import Subprocess
import Synchronization
#if canImport(System)
  import System
#else
  import SystemPackage
#endif

// Runs the Claude Code executor on the server's own host: one process per
// activation, each in a fresh folder deleted when the process ends.
final class ClaudeCodeHost: Sendable {
  let tokens = ClaudeCodeTokens()
  private let loopback = Mutex<String?>(nil)
  private let space: Space
  private let credentials: CredentialResolver
  private let usage: UsageBoard
  private let installation: ClaudeCodeInstallation?
  private let origin: String
  private let run: Result<ClaudeCodeRun, ClaudeCodeRunError>

  // Activations live in this run's own folder, so nothing another server
  // does to its folders reaches them; each is deleted when its process ends.
  init(
    space: Space,
    credentials: CredentialResolver,
    usage: UsageBoard,
    configDirectory: URL?,
    origin: String,
    spaceID: String,
  ) {
    self.space = space
    self.credentials = credentials
    self.usage = usage
    @Dependency(ClaudeInstallEnvironment.self) var environment
    installation = configDirectory.map { ClaudeCodeInstallation(ClaudeInstaller(configDirectory: $0, environment: environment)) }
    self.origin = origin
    run = Result {
      guard let configDirectory else { throw ClaudeCodeRunError("this server has no configured directory") }
      return try ClaudeCodeRun.claim(configDirectory: configDirectory, spaceID: spaceID)
    }.mapError { $0 as? ClaudeCodeRunError ?? ClaudeCodeRunError("\($0)") }
    if case let .failure(error) = run {
      Logger(label: "wuhu.claude-code").warning("no run folder; Claude Code sessions cannot start", metadata: ["error": "\(error)"])
    }
  }

  private func activations() throws -> String {
    switch run {
    case let .success(run): run.activations
    case let .failure(error): throw ClaudeCodeLaunchError("Claude Code has no run folder: \(error)")
    }
  }

  func installInBackground() {
    guard let installation else { return }
    Task {
      do {
        _ = try await installation.ready()
      } catch {
        Logger(label: "wuhu.claude-code").warning("Claude Code \(ClaudeCode.version) could not be installed", metadata: ["error": "\(error)"])
      }
    }
  }

  func serveLoopback(on base: String) {
    loopback.withLock { $0 = base }
  }

  var seam: ClaudeCodeSeam {
    ClaudeCodeSeam(
      spawn: { try await self.spawn($0) },
      render: { try await self.render($1, channel: $2, session: $0) },
    )
  }

  private func spawn(_ launch: ClaudeCodeLaunch) async throws -> ClaudeCodeProcess {
    let (model, spec) = try await launchSpec(
      session: launch.session,
      claudeSessionID: launch.log.sessionID,
      resume: !launch.log.entries.isEmpty,
    )
    let root = try activations() + "/" + launch.activation.uuidString.lowercased()
    let tokens = tokens
    let (frames, frameSink) = AsyncStream<ClaudeStreamFrame>.makeStream()
    let (outbound, outboundSink) = AsyncStream<[UInt8]>.makeStream()
    let killer = Mutex(Killer.notStarted)
    let log = Logger(label: "wuhu.claude-code")
    let usage = usage
    let space = space
    @Dependency(\.date) var dependencyDate
    let date = dependencyDate
    return ClaudeCodeProcess(
      run: {
        defer {
          frameSink.finish()
          outboundSink.finish()
        }
        if killer.withLock({ $0.killed }) { return "killed before it started" }
        do {
          try FileManager.default.createDirectory(atPath: root + "/work", withIntermediateDirectories: true)
          try FileManager.default.createDirectory(atPath: root + "/config", withIntermediateDirectories: true)
        } catch {
          return "could not create its folder: \(error)"
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let holder = ClaudeCodeTokens.Holder(session: launch.session, activation: launch.activation)
        let token = tokens.mint(holder)
        let ending = await { () async -> String in
          let plan = spec(resolvedPath(root), token).plan
          do {
            for (path, contents) in plan.files {
              try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
            }
            if !launch.log.entries.isEmpty {
              try await launch.log.write(configDirectory: plan.configDirectory, workingFolder: plan.workingFolder)
            }
          } catch {
            return "could not write its folder: \(error)"
          }
          var options = PlatformOptions()
          options.processGroupID = 0
          options.teardownSequence = [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .seconds(1))]
          do {
            let result = try await Subprocess.run(
              .path(FilePath(plan.executable)),
              arguments: Arguments(plan.arguments),
              environment: .custom(Dictionary(uniqueKeysWithValues: plan.environment.map {
                (Environment.Key(stringLiteral: $0.key), $0.value)
              })),
              workingDirectory: FilePath(plan.workingFolder),
              platformOptions: options,
              input: .inputWriter,
              output: .sequence,
              error: .sequence,
            ) { execution in
              let kill = { @Sendable in _ = try? execution.send(signal: .kill, toProcessGroup: true) }
              if killer.withLock({ state in
                defer { state = .running(kill) }
                return state.killed
              }) { kill() }
              await withTaskGroup(of: Void.self) { group in
                group.addTask {
                  do {
                    for await bytes in outbound {
                      _ = try await execution.standardInputWriter.write(bytes)
                    }
                    try await execution.standardInputWriter.finish()
                  } catch {
                    kill()
                  }
                }
                await withTaskGroup(of: Void.self) { pumps in
                  pumps.addTask {
                    var reader = ClaudeStreamReader()
                    var calls = ClaudeInferenceCalls()
                    func consume(_ frame: ClaudeStreamFrame) async {
                      await recordClaudeInferences(calls.record(frame, at: date.now.ISO8601Format(.init(includingFractionalSeconds: true))), space: space, session: launch.session, model: model, logger: log)
                      if case let .other(value) = frame, value.object?["type"]?.stringValue == "stream_event" { return }
                      if case let .rateLimit(limit) = frame {
                        usage.record(model.provider, plan: nil, windows: claudeUsage(limit), at: date.now)
                      }
                      frameSink.yield(frame)
                    }
                    do {
                      for try await buffer in execution.standardOutput {
                        for frame in reader.read(buffer.withUnsafeBytes { Array($0) }) {
                          await consume(frame)
                        }
                      }
                    } catch {}
                    if let last = reader.finish() { await consume(last) }
                    await recordClaudeInferences(calls.drain(), space: space, session: launch.session, model: model, logger: log)
                    frameSink.finish()
                  }
                  pumps.addTask {
                    do {
                      for try await buffer in execution.standardError {
                        let text = String(decoding: buffer.withUnsafeBytes { Array($0) }, as: UTF8.self)
                        log.notice("claude code stderr", metadata: ["session": "\(launch.session.rawValue)", "text": "\(text)"])
                      }
                    } catch {}
                  }
                }
                group.cancelAll()
              }
            }
            killer.withLock { $0 = .ended }
            return switch result.terminationStatus {
            case let .exited(code): "exit status \(code)"
            case let .signaled(signal): "signal \(signal)"
            }
          } catch {
            killer.withLock { $0 = .ended }
            return "could not start: \(error)"
          }
        }()
        await tokens.end(launch.activation)
        return ending
      },
      frames: frames,
      write: { bytes in
        if case .terminated = outboundSink.yield(bytes) { throw ClaudeCodeLaunchError("Claude Code's standard input is closed") }
      },
      kill: {
        let running = killer.withLock { state -> (@Sendable () -> Void)? in
          switch state {
          case .notStarted:
            state = .killedEarly
            return nil
          case let .running(kill):
            return kill
          case .killedEarly, .ended:
            return nil
          }
        }
        running?()
      },
    )
  }

  // Everything a launch settles before its process exists: the checks, and
  // the command for a folder and a token that only the process's run knows.
  // The system prompt is the session's frozen one (see frozenPrompt).
  func launchSpec(
    session: SessionID,
    claudeSessionID: UUID,
    resume: Bool,
  ) async throws -> (model: ModelSpecifier, spec: @Sendable (_ root: String, _ token: String) -> ClaudeCodeLaunchSpec) {
    let record = try await space.sessions.record(session)
    guard case let .claudeCode(model) = record.executor else {
      preconditionFailure("the Claude Code seam spawned for a \(record.executor.kind) session")
    }
    guard case let .claudeCodeOAuth(oauth)? = try await credentials.resolve(model.provider) else {
      throw ClaudeCodeLaunchError("provider \(model.provider) has no Claude Code setup token; store one with: wuhu auth login \(model.provider)")
    }
    guard let installation else { throw ClaudeCodeLaunchError("Claude Code has no config directory to be installed in") }
    let binary: String
    do {
      binary = try await installation.ready().path
    } catch {
      throw ClaudeCodeLaunchError("Claude Code \(ClaudeCode.version) could not be installed at \(installation.installer.binaryPath.path): \(error)")
    }
    guard let loopback = loopback.withLock({ $0 }) else {
      throw ClaudeCodeLaunchError("the Claude Code loopback listener is not bound yet")
    }
    let autocompact = try await autocompactWindow(of: model)
    let systemPrompt = try await claudeCodeSystemPrompt(space: space, record: record, origin: origin)
    let inherited = ProcessInfo.processInfo.environment
    let spec = { @Sendable (root: String, token: String) in
      ClaudeCodeLaunchSpec(
        root: root,
        binary: binary,
        loopback: loopback,
        token: token,
        session: session,
        claudeSessionID: claudeSessionID.uuidString.lowercased(),
        resume: resume,
        model: model.model,
        effort: model.effort,
        autocompact: autocompact,
        systemPrompt: systemPrompt,
        oauthToken: oauth,
        inherited: inherited,
      )
    }
    return (model, spec)
  }

  // A setup token carries no profile scope, so Claude Code's own usage read
  // answers nothing; the plan's windows ride only on inference responses. One
  // cheap turn on a fresh process, no tools and no settings, reads them.
  func probeUsage(provider: String) async -> ClaudeUsageProbe {
    guard let binary = installation?.installer.binaryPath.path, FileManager.default.isExecutableFile(atPath: binary) else {
      return .notInstalled
    }
    return await .probed(probeUsage(provider: provider, binary: binary))
  }

  private func probeUsage(provider: String, binary: String) async -> ClaudeStreamFrame.RateLimit? {
    @Dependency(\.continuousClock) var dependencyClock
    let clock = dependencyClock
    guard case let .claudeCodeOAuth(oauth)? = try? await credentials.resolve(provider) else { return nil }
    guard let activations = try? activations() else { return nil }
    let root = activations + "/usage-" + UUID().uuidString.lowercased()
    do {
      try FileManager.default.createDirectory(atPath: root + "/config", withIntermediateDirectories: true)
    } catch {
      return nil
    }
    defer { try? FileManager.default.removeItem(atPath: root) }
    var environment = ProcessInfo.processInfo.environment.filter { ClaudeCodeLaunchSpec.inheritedKeys.contains($0.key) }
    environment["CLAUDE_CONFIG_DIR"] = root + "/config"
    environment["CLAUDE_CODE_OAUTH_TOKEN"] = oauth
    environment["DISABLE_AUTOUPDATER"] = "1"
    let prompt = #"{"type":"user","message":{"role":"user","content":"Reply with the single word: ok"}}"# + "\n"
    var options = PlatformOptions()
    options.processGroupID = 0
    options.teardownSequence = [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .seconds(1))]
    do {
      return try await Subprocess.run(
        .path(FilePath(binary)),
        arguments: Arguments([
          "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
          "--model", claudeUsageProbeModel, "--tools", "", "--setting-sources", "", "--strict-mcp-config",
        ]),
        environment: .custom(Dictionary(uniqueKeysWithValues: environment.map {
          (Environment.Key(stringLiteral: $0.key), $0.value)
        })),
        workingDirectory: FilePath(root),
        platformOptions: options,
        input: .inputWriter,
        output: .sequence,
        error: .discarded,
      ) { execution -> ClaudeStreamFrame.RateLimit? in
        let kill = { @Sendable in _ = try? execution.send(signal: .kill, toProcessGroup: true) }
        _ = try await execution.standardInputWriter.write(Array(prompt.utf8))
        try await execution.standardInputWriter.finish()
        return await withTaskGroup(of: ClaudeStreamFrame.RateLimit?.self) { group in
          group.addTask {
            var reader = ClaudeStreamReader()
            do {
              for try await buffer in execution.standardOutput {
                for frame in reader.read(buffer.withUnsafeBytes { Array($0) }) {
                  switch frame {
                  case let .rateLimit(limit): return limit
                  case .assistant, .result: return nil
                  default: continue
                  }
                }
              }
            } catch {}
            return nil
          }
          group.addTask {
            try? await clock.sleep(for: .seconds(60))
            return nil
          }
          let first = await group.next() ?? nil
          group.cancelAll()
          kill()
          return first
        }
      }.closureResult
    } catch {
      Logger(label: "wuhu.usage").notice("claude usage probe failed", metadata: ["provider": "\(provider)", "error": "\(error)"])
      return nil
    }
  }

  // Read per activation, so an edit to /models.json takes effect at the next one.
  private func autocompactWindow(of specifier: ModelSpecifier) async throws -> Int? {
    let (_, data) = try await space.fs(.shared).read(ModelsDocument.spacePath)
    let model = try ProviderCatalog(document: ModelsDocument(json: data), credentials: .unavailable).validate(specifier)
    return try model.claudeCodeAutocompact(specifier)
  }

  func render(_ inputs: [QueueInput], channel: ClaudeCodeChannel, session: SessionID) async throws -> [ClaudeCodeBlock] {
    let group = try await space.principal(of: session).group
    let handles = try await space.handlesByPrincipal()
    let devices = try await space.deviceNames()
    var blocks: [ClaudeCodeBlock] = []
    for input in inputs {
      blocks.append(.text(input.rendered(handles: handles, devices: devices)))
      guard channel == .standardInput else { continue }
      for image in input.content.modelImages where claudeCodeImageTypes.contains(image.mimeType) {
        // A vanished attachment drops its block, as the kernel's resolver
        // does; its path is still in the text.
        guard let data = try? await space.attachmentBytes(image.path, readingIn: group) else { continue }
        switch ImageFitting.fit(data, mimeType: image.mimeType, limits: .claude) {
        case let .image(fitted, mimeType): blocks.append(.image(mediaType: mimeType, base64: fitted.base64EncodedString()))
        case let .note(note): blocks.append(.text(note))
        }
      }
    }
    return blocks
  }

  // The gate of the loopback listener: only an activation's own token, only
  // for its own session, only while that session is live.
  func holder(of request: Request, acting session: SessionID) async -> Result<ClaudeCodeTokens.Holder, ClaudeCodeRefusal> {
    guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
          let holder = tokens.holder(ofBearer: String(header.dropFirst("Bearer ".count)))
    else { return .failure(.unauthorized) }
    guard holder.session == session else { return .failure(.foreignSession) }
    guard let record = try? await space.sessions.record(session), case .live = record.lifecycle else {
      return .failure(.archived)
    }
    return .success(holder)
  }
}

private enum Killer {
  case notStarted
  case killedEarly
  case running(@Sendable () -> Void)
  case ended

  var killed: Bool {
    if case .killedEarly = self { true } else { false }
  }
}

enum ClaudeCodeRefusal: Error {
  case unauthorized
  case foreignSession
  case archived
}

private let claudeCodeImageTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

struct ClaudeCodeLaunchError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

// Claude Code names its project folder after the real path of its working
// folder, so every path handed to it is resolved first.
private func resolvedPath(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}
