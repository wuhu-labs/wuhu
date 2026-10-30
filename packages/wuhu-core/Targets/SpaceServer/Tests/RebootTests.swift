import AsyncHTTPClient
import Fetch
import FetchAsyncHTTPClient
import Foundation
import MachineContract
import MainHub
import Scratch
import Serve
import ServeNIO
import SessionDomain
@testable import SpaceServer
import Testing

@Suite struct RebootTests {
  // What main holds only in memory crosses to the main it becomes, once: a
  // running exec's token and its OIDC grant still work there.
  @Test func theHandoverCarriesTheTokensOnceAndOnlyToItsOwner() throws {
    let before = ExecTokens(spaceURL: "http://main")
    let now = Date()
    let exec = before.credential(session: SessionID("s1"), exec: ExecID(rawValue: "ex_aaaaaaaa"), timeout: 600, now: now)
    let grant = before.idTokens.environment(
      spaceURL: "http://main", session: SessionID("s1"), machine: MachineID(rawValue: "mc_aaaaaaaa"), exec: ExecID(rawValue: "ex_aaaaaaaa"),
      timeout: 600, now: now,
    )
    let folder = try ScratchFolder("handover")
    defer { folder.remove() }
    let file = URL(fileURLWithPath: folder.path).appendingPathComponent("handover.json")
    try Handover(tokens: before.table(), minted: 3, workers: [.init(id: "worker-3", pid: 42)], wakes: ["s1": 99]).write(to: file)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)

    let handover = try Handover.take(from: file)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let after = ExecTokens(spaceURL: "http://main")
    after.restore(handover.tokens) { _ in { true } }
    #expect(after.holder(ofBearer: exec.token, now: now)?.session == SessionID("s1"))
    #expect(after.idTokens.grant(ofBearer: grant.request, now: now)?.exec == ExecID(rawValue: "ex_aaaaaaaa"))
    #expect(handover.minted == 3 && handover.workers.map(\.pid) == [42] && handover.wakes == ["s1": 99])
  }

  // The listener outlives the server serving it: a request made while no
  // server accepts waits in the backlog and is answered by the next one.
  @Test func aRequestMadeBetweenTwoServersWaitsForTheSecond() async throws {
    let socket = "/tmp/wr-\(UUID().uuidString.prefix(8)).sock"
    defer { unlink(socket) }
    let listeners = try Listeners.open(host: "127.0.0.1", port: 0, workerSocket: socket)
    defer { for fd in [listeners.api, listeners.workers] { close(fd) } }
    func serving(_ answer: String) async throws -> ServeNIOServer {
      try await ServeNIOServer.bind(listeningSocket: listeners.lend(listeners.workers)) { _ in .response(jsonResponse(.string(answer))) }
    }
    var configuration = HTTPClient.Configuration()
    configuration.maximumUsesPerConnection = 1
    let http = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    defer { try? await http.shutdown() }
    let fetch = unixSocketFetch(.asyncHTTPClient(http), socket: socket)
    func ask() async throws -> String { try await fetch.fetch(Request(url: URL(string: "http://main/v1/server")!)).text() }

    let first = try await serving("one")
    #expect(try await ask() == "\"one\"")
    await first.stopAccepting()
    await first.shutdown()
    let waiting = Task { try await ask() }
    let queued = Task { await pendingConnection(on: listeners.workers) }
    Task { _ = await waiting.result; queued.cancel() }
    await queued.value
    let second = try await serving("two")
    #expect(try await waiting.value == "\"two\"")
    await second.shutdown()
  }
}

/// Returns once a connection is queued on `listener`, or once cancelled.
private func pendingConnection(on listener: CInt) async {
  var fds: [CInt] = [-1, -1]
  guard pipe(&fds) == 0 else {
    Issue.record("pipe failed: \(errno)")
    return
  }
  let (wake, woken) = (fds[1], fds[0])
  defer { close(wake); close(woken) }
  await withTaskCancellationHandler {
    await withCheckedContinuation { pending in
      Thread.detachNewThread {
        var events = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: woken, events: Int16(POLLIN), revents: 0)]
        while poll(&events, 2, -1) < 0, errno == EINTR {}
        pending.resume()
      }
    }
  } onCancel: {
    var byte: UInt8 = 0
    _ = write(wake, &byte, 1)
  }
}
