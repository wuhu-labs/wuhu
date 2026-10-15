#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import MachineContract
import OperationClient
import OperationProtocol
@testable import OperationRuntime
import Synchronization
import Testing

private func withoutPaging(_ descriptor: KindDescriptor, removing keys: [String] = ["matchLimit", "resumeEntries", "resumeLine"]) -> KindDescriptor {
  var schema = descriptor.inputSchema.object!
  var properties = schema["properties"]!.object!
  for key in keys { properties.removeValue(forKey: key) }
  schema["properties"] = .object(properties)
  return KindDescriptor(descriptor.name, inputSchema: .object(schema), resultSchema: descriptor.resultSchema, inputChannels: descriptor.inputChannels, outputChannels: descriptor.outputChannels, deliveryPolicy: descriptor.deliveryPolicy)
}

private struct CapabilityKind: OperationKind {
  typealias Input = JSONValue
  let descriptor: KindDescriptor
  func run(_ input: JSONValue, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    if let channel = descriptor.outputChannels.first {
      let record: JSONValue = descriptor.name == "find.v1" ? ["path": "/fixture", "kind": "file"] : ["path": "/fixture", "line": "1", "text": "match"]
      try await channels.send(.init(records: [record]), to: channel.name)
      return ["scanned": "1", "matched": "1", "skipped": [:]]
    }
    return ["name": "fixture", "kind": "file", "size": 1, "token": "opaque", "mtime": 0]
  }
}

private final class PostCount: Sendable {
  let value = Mutex(0)
}

private func capabilityClient(_ descriptors: [KindDescriptor], posts: PostCount) throws -> OperationClient {
  let agent = try OperationAgent(machine: "disk", kinds: descriptors.map { .init(CapabilityKind(descriptor: $0)) }, authorize: { _, _ in })
  return try OperationClient(origin: URL(string: "https://memory.invalid")!, fetch: FetchClient { request in
    if request.method == .post { posts.value.withLock { $0 += 1 } }
    let response = try await agent.handler(request)
    if request.method == .post, let id = UUID(uuidString: request.url.lastPathComponent) { await agent.execute(id) }
    return response
  }, store: MemoryOperationStore(), abort: { _ in }, trace: { _ in })
}

private func searchQuery(_ kind: String, step: String? = nil) -> SearchQuery {
  kind == "find.v1" ? .find(glob: "*", path: "/", matchLimit: nil, entryLimit: nil, step: step) : .grep(pattern: "match", path: "/", matchLimit: nil, entryLimit: nil, step: step)
}

@Suite struct CapabilityCompatibilityTests {
  @Test func dev119MissingFilesystemKindsRefuseBeforePost() async throws {
    let posts = PostCount()
    let client = try capabilityClient([ComputerKindSchemas.exec, ComputerKindSchemas.read, withoutPaging(ComputerKindSchemas.find), withoutPaging(ComputerKindSchemas.grep)], posts: posts)
    let operations: [(String, VFSOp)] = [
      ("stat.v1", .stat(path: "/fixture")),
      ("list.v1", .ls(path: "/")),
      ("write.v1", .write(path: "/fixture", data: .init([1]), ifMatch: nil)),
      ("mkdir.v1", .mkdir(path: "/dir")),
      ("remove.v1", .rm(path: "/fixture", ifMatch: nil)),
      ("move.v1", .mv(from: "/fixture", to: "/other")),
    ]
    for (kind, op) in operations {
      do {
        _ = try await client.vfs(machine: "disk", op: op, owner: .init(scope: "compatibility", key: kind))
        Issue.record("Expected missing filesystem capability refusal")
      } catch let error as OperationError {
        #expect(error.code == .unknownKind)
        #expect(error.message.contains(kind))
        #expect(error.message.contains("agent too old, upgrade"))
      }
    }
    #expect(posts.value.withLock { $0 } == 0)
    await client.shutdown()
  }

  @Test(arguments: ["find.v1", "grep.v1"]) func dev119SearchRefusesBeforePost(kind: String) async throws {
    let posts = PostCount()
    let client = try capabilityClient([ComputerKindSchemas.exec, ComputerKindSchemas.read, withoutPaging(ComputerKindSchemas.find), withoutPaging(ComputerKindSchemas.grep)], posts: posts)
    do {
      _ = try await client.search(machine: "disk", query: searchQuery(kind))
      Issue.record("Expected old search capability refusal")
    } catch let error as OperationError {
      #expect(error.code == .kindUnavailable)
      #expect(error.message.contains(kind))
      #expect(error.message.contains("agent too old, upgrade"))
      #expect(error.details == ["kind": .string(kind), "reason": "agentTooOld", "started": false])
    }
    #expect(posts.value.withLock { $0 } == 0)
    await client.shutdown()
  }

  @Test(arguments: ["find.v1", "grep.v1"]) func missingSearchKindRefusesBeforePost(kind: String) async throws {
    let posts = PostCount()
    let client = try capabilityClient([], posts: posts)
    do {
      _ = try await client.search(machine: "disk", query: searchQuery(kind))
      Issue.record("Expected missing search capability refusal")
    } catch let error as OperationError {
      #expect(error.code == .kindUnavailable)
      #expect(error.message.contains("agent too old, upgrade"))
    }
    #expect(posts.value.withLock { $0 } == 0)
    await client.shutdown()
  }

  @Test(arguments: ["matchLimit", "resumeEntries", "resumeLine"]) func eachPagingCapabilityIsRequiredOnFirstPage(property: String) async throws {
    let posts = PostCount()
    let client = try capabilityClient([withoutPaging(ComputerKindSchemas.find, removing: [property])], posts: posts)
    do {
      _ = try await client.search(machine: "disk", query: searchQuery("find.v1"))
      Issue.record("Expected incomplete paging capability refusal")
    } catch let error as OperationError { #expect(error.code == .kindUnavailable) }
    #expect(posts.value.withLock { $0 } == 0)
    await client.shutdown()
  }

  @Test(arguments: ["find.v1", "grep.v1"]) func currentSearchDescriptorStillDispatchesAndReturnsRecords(kind: String) async throws {
    let posts = PostCount()
    let client = try capabilityClient([ComputerKindSchemas.find, ComputerKindSchemas.grep], posts: posts)
    let result = try await client.search(machine: "disk", query: searchQuery(kind))
    if kind == "find.v1" { #expect(result == .paths(paths: ["/fixture"], cursor: nil)) }
    else { #expect(result == .matches(matches: [.init(path: "/fixture", line: 1, text: "match", context: [])], cursor: nil)) }
    #expect(posts.value.withLock { $0 } == 1)
    await client.shutdown()
  }

  @Test func currentFilesystemDescriptorStillDispatches() async throws {
    let posts = PostCount()
    let client = try capabilityClient([ComputerKindSchemas.stat], posts: posts)
    let result = try await client.vfs(machine: "disk", op: .stat(path: "/fixture"), owner: .init(scope: "compatibility", key: "stat"))
    guard case let .entry(entry) = result else { Issue.record("Expected metadata result"); await client.shutdown(); return }
    #expect(entry.name == "fixture")
    #expect(entry.token == "opaque")
    #expect(posts.value.withLock { $0 } == 1)
    await client.shutdown()
  }

  @Test func unadvertisedInputIsRefusedBeforePost() async throws {
    let posts = PostCount()
    let client = try capabilityClient([withoutPaging(ComputerKindSchemas.remove, removing: ["ifMatch"])], posts: posts)
    do {
      _ = try await client.vfs(machine: "disk", op: .rm(path: "/fixture", ifMatch: "opaque"), owner: .init(scope: "compatibility", key: "remove"))
      Issue.record("Expected unadvertised input refusal")
    } catch let error as OperationError {
      #expect(error.code == .kindUnavailable)
      #expect(error.message.contains("remove.v1"))
      #expect(error.message.contains("agent too old, upgrade"))
      #expect(error.details == ["kind": "remove.v1", "reason": "agentTooOld", "started": false, "inputs": ["ifMatch"]])
    }
    #expect(posts.value.withLock { $0 } == 0)
    await client.shutdown()
  }

  @Test func openInputSchemaIsNotGuarded() async throws {
    let posts = PostCount()
    let open = KindDescriptor("probe.v1", inputSchema: ["type": "object", "properties": ["path": ["type": "string"]]], resultSchema: ["type": "object"], deliveryPolicy: .boundedResult)
    let client = try capabilityClient([open], posts: posts)
    _ = try await client.describe("disk")
    _ = try await client.start("disk", request: .init(kind: "probe.v1", input: ["path": "/fixture", "future": true]), owner: .init(scope: "compatibility", key: "probe"))
    #expect(posts.value.withLock { $0 } == 1)
    await client.shutdown()
  }
}
