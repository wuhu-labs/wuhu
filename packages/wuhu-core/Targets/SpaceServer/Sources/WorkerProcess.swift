#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import AsyncHTTPClient
import struct Credentials.CredentialResolver
import struct Credentials.CredentialsStore
import enum Credentials.UserConfig
import Dependencies
import Fetch
import FetchAsyncHTTPClient
import FetchWebSocket
import InferenceKit
import Logging
import struct LoopCore.SessionExecution
import protocol MachineChannel.FrameTransport
import MainHub
import SessionDomain
import SessionTools
import struct SpaceClient.SpaceClient
import enum SpaceContract.ScriptOutput
import Synchronization

/// A worker in a process of its own: what `wuhu` runs when main starts it
/// with `WUHU_ROLE=worker`. It reaches main only over main's worker socket,
/// with the credential main wrote to its standard input, and keeps its line
/// to main open, opening it again when it drops, until main shuts it down
/// or main is gone.
public enum WorkerProcess {
  public static let roleVariable = "WUHU_ROLE"
  public static let role = "worker"
  static let socketVariable = "WUHU_WORKER_SOCKET"
  static let spaceVariable = "WUHU_SPACE_ID"
  /// What a main hands to the main it `execve`s into, never to a worker.
  static let inheritedOnlyByMain = [Reboot.listenersVariable, Reboot.handoverVariable]

  /// Runs the worker until main shuts it down; returns the exit status.
  public static func run(environment: [String: String]) async -> Int32 {
    let log = Logger(label: "wuhu.worker")
    guard let socket = environment[socketVariable], let spaceID = environment[spaceVariable] else {
      log.error("a worker is started by main, with \(socketVariable) and \(spaceVariable)")
      return 64
    }
    guard let credential = readLine(strippingNewline: true), !credential.isEmpty else {
      log.error("a worker reads its credential from its standard input")
      return 64
    }
    // Main's terminal and its reboot are main's; main shuts its workers down.
    signal(SIGINT, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    let parent = getppid()
    let clock: any Clock<Duration> = Dependency(\.continuousClock).wrappedValue

    let credentials: CredentialResolver
    if let configDirectory = try? UserConfig.directory(environment: environment) {
      credentials = .live(store: CredentialsStore(configDirectory: configDirectory, spaceID: spaceID))
    } else {
      credentials = .environmentOnly
    }
    let connection = MainConnection()
    let access = MainClient(connection: connection, credential: { credential }).inferenceAccess(credentials: credentials, trace: attemptLogConfig()?.traceClient)
    var configuration = HTTPClient.Configuration()
    // One request per connection: main finishing what it took before it
    // reboots leaves no idle connection for a request to race into.
    configuration.maximumUsesPerConnection = 1
    let http = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    connection.bind(unixSocketFetch(.asyncHTTPClient(http, timeout: nil), socket: socket), dial: unixSocketDial(socket))

    let notices = WorkerNotices()
    let attempts = AttemptHub { session, event in notices.send(.attempt(session: session, event: event)) }
    let usage = UsageBoard { provider, plan, windows, at in
      notices.send(.usage(provider: provider, plan: plan, windows: windows, at: at.timeIntervalSince1970))
    }
    let worker = await KernelWorker(connection: connection, credential: credential, access: access, attempts: attempts, usage: usage)
    let endpoint = ShutdownWatch(worker.execution)
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await worker.sockets.run() }
      var delay = Duration.milliseconds(100)
      while !endpoint.isShutDown {
        let holding = await worker.execution.holding()
        // The line closes when main does, or when main has shut this worker down.
        let opened = await withTaskGroup(of: Bool?.self) { line in
          line.addTask {
            do {
              log.notice("opening the line to main", metadata: ["holding": "\(holding.count)"])
              try await connection.serveLine(endpoint, credential: credential, holding: holding, notices: notices)
              log.notice("the line to main closed")
              return true
            } catch {
              log.warning("could not open the line to main", metadata: ["error": "\(error)"])
              return false
            }
          }
          line.addTask {
            await endpoint.shutDown()
            return nil
          }
          let first = await line.next() ?? nil
          line.cancelAll()
          return first ?? false
        }
        if opened { delay = .milliseconds(100) }
        guard !endpoint.isShutDown else { break }
        // Main is gone for good, not rebooting: nothing is left to work for.
        guard getppid() == parent else {
          log.error("main is gone; the worker stops")
          await worker.execution.shutdown()
          break
        }
        try? await clock.sleep(for: delay)
        delay = min(delay * 2, .seconds(2))
      }
      group.cancelAll()
    }
    try? await http.shutdown()
    return 0
  }
}

// The worker as its line serves it, noting when main has shut it down.
private final class ShutdownWatch: Worker {
  let execution: SessionExecution
  private let shut = Mutex<(done: Bool, waiting: [UUID: CheckedContinuation<Void, Never>])>((false, [:]))

  init(_ execution: SessionExecution) { self.execution = execution }

  var isShutDown: Bool { shut.withLock { $0.done } }

  /// Returns once main has shut the worker down, or when cancelled.
  func shutDown() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let waits = shut.withLock { state in
          guard !state.done, !Task.isCancelled else { return false }
          state.waiting[id] = continuation
          return true
        }
        if !waits { continuation.resume() }
      }
    } onCancel: {
      shut.withLock { $0.waiting.removeValue(forKey: id) }?.resume()
    }
  }

  func deliver(_ session: SessionID, _ input: WorkerInput) async throws { try await execution.deliver(session, input) }
  func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool { try await execution.revoke(session, policy: policy) }
  func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult { try await execution.fire(invocation) }
  func run(_ script: ScriptRun, output: @escaping @Sendable (ScriptOutput) -> Void) async throws { try await execution.run(script, output: output) }
  func activity() async -> WorkerActivity { await execution.activity() }
  func runningWork(_ session: SessionID) async throws -> [String] { try await execution.runningWork(session) }
  func shutdown() async {
    await execution.shutdown()
    let waiting = shut.withLock { state in
      state.done = true
      defer { state.waiting = [:] }
      return state.waiting.values
    }
    for waiter in waiting { waiter.resume() }
  }
}

/// Main's API at `http://main/…` over its worker socket.
func unixSocketFetch(_ client: FetchClient, socket: String) -> FetchClient {
  // The socket's path is the URL's host, every byte but the unreserved ones escaped.
  let host = socket.utf8.map { byte -> String in
    let unreserved = (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte) || "-._~".utf8.contains(byte)
    return unreserved ? String(UnicodeScalar(byte)) : "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
  }.joined()
  return FetchClient { request in
    var request = request
    let path = request.url.path(percentEncoded: true)
    let query = request.url.query(percentEncoded: true).map { "?" + $0 } ?? ""
    guard let url = URL(string: "http+unix://" + host + path + query) else { throw MainUnavailable() }
    request.url = url
    // Main reads the host off the request; the socket's path is no host.
    request.headers["host"] = "main"
    return try await client.fetch(request)
  }
}

/// A websocket to main's API over its worker socket: the worker's line, and
/// an exec's caller leg.
func unixSocketDial(_ socket: String) -> @Sendable (URL, [(String, String)]) async throws -> any FrameTransport {
  { url, headers in
    do {
      return DuplexTransport(socket: try await WebSocketClient.connect(
        url: url, headers: headers, maxFrameBytes: MachineHub.maximumFrameBytes, unixSocketPath: socket,
      ))
    } catch let WebSocketClientError.refused(status, body) {
      throw SpaceClient.DialRefusal(status: status, body: body)
    }
  }
}

private struct DuplexTransport: FrameTransport {
  let socket: WebSocketDuplex
  var inbound: AsyncStream<[UInt8]> { socket.inbound }
  func send(_ frame: [UInt8]) async throws { try await socket.send(frame) }
  func close() { socket.close() }
}

extension String {
  fileprivate func leftPadded(to width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}
