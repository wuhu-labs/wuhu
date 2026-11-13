import Clocks
import ContentLane
import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
import JSONValue
import MachineChannel
import struct MachineContract.ExecID
import Serve
import ServeTesting
import SessionDomain
import SpaceContract
import struct SpaceContract.GroupID
@testable import SpaceCore
@testable import SpaceServer
import SpaceTools
import Testing

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func testPubkey(_ seed: String) -> String {
  let bytes = Array(seed.utf8.prefix(32))
  return "ed25519:" + Data(bytes + repeatElement(0, count: 32 - bytes.count)).base64EncodedString()
}

struct Harness {
  let space: Space
  let context: SpaceToolContext
  /// The one listener: every host, as the request names it.
  let api: FetchClient
  /// The same listener, with a request to any name off the content host
  /// sent to `shared.<host>`: the content of the shared group.
  let web: FetchClient
  let handler: UpgradingHandler

  init(
    dev: Bool = true,
    publicRead: Bool = false,
    origin: String? = nil,
    contentHostPattern: String? = nil,
    aiDisclosure: AIDisclosure? = nil,
    fingerprint: String? = nil,
    webApp: WebApp? = nil,
    views: [String: Data] = [:],
    webPushApplicationServerKey: String? = nil,
    credentials: CredentialResolver = .unavailable,
    pageFetch: PageFetchHandler? = nil,
    identityController: IdentityController? = nil,
    clock: (any NonsendingClock<Duration>)? = nil,
    opening: () throws -> Space = { try Space.inMemory() },
  ) async throws {
    let contentHost = ContentHost(origin: origin ?? "https://localhost", pattern: contentHostPattern)!
    let (space, handler) = try await withDependencies {
      $0.date = .constant(fixedDate)
      $0.continuousClock = clock ?? ContinuousClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 11))
    } operation: {
      let space = try opening()
      let hub = MachineHub(space: space)
      let devPerson = dev ? try await space.ensureDevPerson() : nil
      let handler = SpaceServer.configuredHandler(
        space: space, hub: hub, origin: origin, contentHostPattern: contentHostPattern, aiDisclosure: aiDisclosure,
        fingerprint: fingerprint, devPerson: devPerson, publicRead: publicRead, webContent: WebContent(webApp: webApp, views: views, scripts: ["shell.js": Data(), "worker.js": Data(), "space-core.js": Data("export function createSpace() {}".utf8)]),
        webPushApplicationServerKey: webPushApplicationServerKey,
        credentials: credentials, identityController: identityController, listenerRoutes: machineListenerRoutes(space: space, hub: hub, devPerson: devPerson, fingerprint: fingerprint), pageFetch: pageFetch,
      )
      return (space, handler)
    }
    self.space = space
    self.handler = handler
    self.context = SpaceToolContext(space: space, principal: .shared(dev ? try await space.ensureDevPerson().actor : .publicReader))
    self.api = ServeTesting.client(upgrading: handler)
    self.web = ServeTesting.client(upgrading: { request in
      guard contentHost.plane(of: request.url.host) == .api,
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
      else { return try await handler(request) }
      components.host = "shared." + contentHost.host
      var shared = request
      shared.url = components.url!
      return try await handler(shared)
    })
  }

  func post(_ tool: String, _ input: JSONValue) async throws -> Response {
    try await api(Request(
      url: URL(string: "http://space/v1/tools/\(tool)")!,
      method: .post,
      body: .bytes(Data(input.jsonString().utf8), contentType: "application/json"),
    ))
  }

  func call<Output: Decodable>(_ tool: String, _ input: JSONValue, as output: Output.Type) async throws -> Output {
    let response = try await post(tool, input)
    #expect(response.status == .ok)
    return try JSONValueDecoder().decode(output, from: try await json(response))
  }

  func direct(_ name: String, _ input: JSONValue) async throws -> JSONValue {
    let context = SpaceToolContext(space: space, principal: .shared(try await space.ensureDevPerson().actor))
    return try await SpaceToolbox.all.first { $0.name == name }!.run(context, input: input)
  }

  func get(_ client: FetchClient, _ path: String, query: [String: String] = [:]) async throws -> Response {
    var components = URLComponents(string: "http://space")!
    components.path = path
    if !query.isEmpty {
      components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    return try await client(Request(url: components.url!))
  }
}

func json(_ response: Response) async throws -> JSONValue {
  let text = try await response.text()
  return try #require(JSONValue.parse(text))
}

// An exec's in-process caller leg: what the WebSocket route hands a dialing client.
func connectExecCaller(_ id: ExecID, space: Space, hub: MachineHub) async throws -> any FrameTransport {
  guard let record = try await space.execRecord(id) else { throw MachineHubError.execNotFound(id) }
  let (server, client) = WebSocket.pair()
  let leg: ExecLeg = if let caller = record.caller { .session(SessionID(rawValue: caller)) } else { .person(try await space.ensureDevPerson().account) }
  _ = try? hub.callerScope.run("in-process-exec-caller") {
    await hub.runCallerSession(record, socket: server, leg: leg)
  }
  return WebSocketTransport(client)
}

extension Space {
  func registerPerson(_ id: String) async throws {
    if cell.persona(named: id) != nil { return }
    let account = try await addAccount(kind: .human, name: nil)
    let key = try await addKey(testPubkey(id), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let allocation = try await allocate(.persona, createdBy: key.pubkey)
    let now = fixedDate
    _ = try await worker.call(PersonCell.ID(account.id.rawValue)) { try $0.adoptPersona(key: key, allocation: allocation.id, name: id, at: now) }
  }

  func registerPeople(_ ids: [String]) async throws {
    for id in ids {
      try await registerPerson(id)
      _ = try await setUserProfile(principal: id, handle: "person_" + id.replacingOccurrences(of: "-", with: "_"), displayName: nil)
    }
  }
}

extension Space {
  func privateGroup(account: AccountID) async throws -> GroupID {
    let group = try await createGroup(alias: "fixture_" + account.rawValue, owner: account)
    try await setVisibility(.private, of: group, by: .person(persona: account.rawValue, account: account), acting: group)
    return group
  }

  func seedGroup(_ group: GroupID, owner: AccountID? = nil) async throws {
    let account = if let owner { owner } else { try await addAccount(kind: .human, name: nil).id }
    let claim = GroupClaim(alias: group.rawValue, name: group.rawValue, owner: account, created: "2026-01-01T00:00:00Z")
    try await worker.call(GroupCell.ID(group.rawValue)) { try $0.create(claim) }
    try await setVisibility(.private, of: group, by: .person(persona: account.rawValue, account: account), acting: group)
  }

  /// The group's cell has taken the attempts its mail carried on their way.
  func deliverInferences(_ group: GroupID) async throws {
    let id = GroupCell.ID(group.rawValue)
    while worker.hasMail(for: id.recipient) { await Task.yield() }
    try await worker.call(id) { _ in () }
  }
}
