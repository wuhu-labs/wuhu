#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import GRDB
import OperationClient
import OperationProtocol
import Scratch
import Serve
@testable import SpaceCore
@testable import SpaceServer
import Testing

@Suite struct MachineV2HostIsolationTests {
  enum Damage: CaseIterable, Sendable { case missingKey, corruptKey, corruptRecord }

  @Test(arguments: Damage.allCases) func unusableV2StateDoesNotPreventOpeningTheSpace(_ damage: Damage) async throws {
    let folder = try ScratchFolder("machine-v2-host-isolation")
    let state = folder.url.appendingPathComponent("machine-v2")
    let keyFile = state.appendingPathComponent(MachineV2KeyStore.filename)
    let deployment = DeploymentRecord(origin: "https://isolated.test", tlsFingerprint: "test", certificate: .provided)
    let first = try await SpaceHost.open(folder: folder.url, deployment: deployment, configDirectory: nil, allowEnvironmentCredentials: false, dev: true, webApp: nil)
    let key = try await MachineV2KeyStore.loadOrCreate(directory: state, space: first.space)
    let store = try await first.space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: "offline", start: .init(kind: "query.v1", input: [:]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [.init("query.v1", inputSchema: [:], resultSchema: [:])]))
    _ = try await store.claim(.init(scope: "old-script", key: "one"), record: record)
    try await first.shutdown()
    switch damage {
    case .missingKey: try FileManager.default.removeItem(at: keyFile)
    case .corruptKey: try Data([42]).write(to: keyFile)
    case .corruptRecord:
      try await first.space.writer.write { db in
        try db.execute(sql: "UPDATE machine_v2_operations SET record = ? WHERE id = ?", arguments: ["corrupt", record.id.uuidString])
      }
    }
    let before = try? Data(contentsOf: keyFile)
    let reopened = try await SpaceHost.open(folder: folder.url, deployment: deployment, configDirectory: nil, allowEnvironmentCredentials: false, dev: true, webApp: nil)
    for request in [
      Request(url: URL(string: "https://isolated.test/v1/server")!),
      Request(url: URL(string: "https://isolated.test/v1/machine")!, method: .post, body: try .json(["name": "still-v1"])),
      Request(url: URL(string: "https://isolated.test/v1/f/note.md")!, method: .put, body: .bytes(Data("ordinary files still work".utf8))),
    ] {
      guard case let .response(response) = try await reopened.handler(request) else { Issue.record("ordinary route upgraded"); continue }
      #expect((200 ..< 300).contains(response.status.code))
    }
    for path in ["/v1/machine-v2/challenge", "/v1/machine-v2"] {
      let request = Request(url: URL(string: "https://isolated.test" + path)!, method: path.hasSuffix("challenge") ? .get : .post, body: path.hasSuffix("challenge") ? nil : try .json(["name": "blocked-v2"]))
      guard case let .response(response) = try await reopened.handler(request) else { Issue.record("unavailable v2 upgraded"); continue }
      #expect(response.status == .serviceUnavailable)
      #expect(try await response.body.json(ErrorEnvelope.self).error.code == .storeUnavailable)
    }
    let hub = MachineV2Hub(space: reopened.space)
    let service = await MachineV2Service.open(space: reopened.space, hub: hub, directory: state)
    do { _ = try await service.client(group: .shared); Issue.record("unavailable v2 script client admitted") }
    catch let error as OperationError { #expect(error.code == .storeUnavailable) }
    do { _ = try await hub.fetch(Request(url: URL(string: "https://isolated.test/machine/v2/machines/offline")!), usableFrom: .shared); Issue.record("unavailable v2 route admitted") }
    catch let error as OperationError { #expect(error.code == .storeUnavailable) }
    #expect((try? Data(contentsOf: keyFile)) == before)
    await service.shutdown()
    try await reopened.shutdown()
  }
}
