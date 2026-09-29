import Dependencies
import Foundation
import Logging
import MachineChannel
import MachineContract

public final class MachineAgent: Sendable {
  private let endpoint: ChannelEndpoint = ChannelEndpoint()
  private let stateDirectory: URL
  private let registry: ExecRegistry = ExecRegistry()
  private let engine: ExecEngine
  private let clock: any Clock<Duration>
  private let disconnectGrace: Duration
  private let logger: Logger

  public convenience init(
    stateDirectory: String,
    killGrace: Duration = .seconds(5),
    disconnectGrace: Duration = .seconds(300),
  ) {
    self.init(stateDirectory: stateDirectory, killGrace: killGrace, disconnectGrace: disconnectGrace, logger: Logger(label: "MachineAgent"))
  }

  init(stateDirectory: String, killGrace: Duration, disconnectGrace: Duration, logger: Logger) {
    @Dependency(\.continuousClock) var clock
    self.clock = clock
    self.disconnectGrace = disconnectGrace
    self.logger = logger
    self.stateDirectory = URL(fileURLWithPath: stateDirectory, isDirectory: true)
    engine = ExecEngine(registry: registry, clock: clock, killGrace: killGrace, logger: logger)
  }

  public func run(dial: @escaping @Sendable () async throws -> any FrameTransport) async {
    if FileManager.default.fileExists(atPath: legacyVault.path) {
      logger.notice("\(legacyVault.path) is no longer used: an exec's secrets are its machine's group secrets (wuhu secret set)")
    }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.serveExecs() }
      group.addTask { await self.serveRequests() }
      group.addTask { await self.maintainConnection(dial: dial) }
    }
  }

  // Left in place: its values are the owner's to move with `wuhu secret set`.
  var legacyVault: URL {
    stateDirectory.appendingPathComponent("vault.json")
  }

  private func serveExecs() async {
    await withDiscardingTaskGroup { group in
      for await exec in endpoint.incomingExecs {
        group.addTask { await self.engine.run(exec) }
      }
    }
  }

  private func serveRequests() async {
    await withDiscardingTaskGroup { group in
      for await request in endpoint.inboundRequests {
        group.addTask { await self.handle(request) }
      }
    }
  }

  private func handle(_ request: InboundRequest) async {
    switch request {
    case let .vfs(request):
      await endpoint.respond(.vfs(VFSResponse(id: request.id, result: MachineVFS.execute(request.op))))
    case let .search(request):
      await endpoint.respond(.search(SearchResponse(id: request.id, result: MachineSearch.execute(request.query))))
    }
  }

  private func maintainConnection(dial: @escaping @Sendable () async throws -> any FrameTransport) async {
    while !Task.isCancelled {
      guard let transport = await dialRacingGrace(dial: dial) else { return }
      await endpoint.run(transport)
      logger.info("machine channel severed; redialing")
    }
  }

  private enum DialOutcome: Sendable {
    case dialed(any FrameTransport)
    case graceExpired
    case cancelled
  }

  // The grace watchdog races the whole dial-with-backoff loop: past the
  // disconnect grace every live exec group is killed, but dialing continues
  // forever — reconnecting within the grace resumes execs seamlessly.
  private func dialRacingGrace(dial: @escaping @Sendable () async throws -> any FrameTransport) async -> (any FrameTransport)? {
    await withTaskGroup(of: DialOutcome.self) { group in
      group.addTask {
        do {
          try await self.clock.sleep(for: self.disconnectGrace)
          return .graceExpired
        } catch {
          return .cancelled
        }
      }
      group.addTask {
        var attempt = 0
        while !Task.isCancelled {
          do {
            return try await .dialed(dial())
          } catch is CancellationError {
            return .cancelled
          } catch {
            self.logger.warning("dial failed: \(error)")
          }
          do {
            try await self.clock.sleep(for: Self.backoffDelay(attempt: attempt))
          } catch {
            return .cancelled
          }
          attempt += 1
        }
        return .cancelled
      }
      defer { group.cancelAll() }
      while let outcome = await group.next() {
        switch outcome {
        case let .dialed(transport):
          return transport
        case .graceExpired:
          logger.warning("server absent past grace; killing live exec groups")
          registry.killAll()
        case .cancelled:
          return nil
        }
      }
      return nil
    }
  }

  // Deterministic doubling, no jitter: 1s, 2s, 4s, ..., capped at 30s.
  static func backoffDelay(attempt: Int) -> Duration {
    .seconds(min(30, 1 << min(attempt, 5)))
  }
}
