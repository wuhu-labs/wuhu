#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FileSearch
import enum JSONValue.JSONValue
import MachineContract
import OperationClient
import OperationProtocol
@testable import OperationRuntime
import Synchronization
import Testing

private func withoutInput(_ descriptor: KindDescriptor, removing keys: [String]) -> KindDescriptor {
  var schema = descriptor.inputSchema.object!
  var properties = schema["properties"]!.object!
  for key in keys { properties.removeValue(forKey: key) }
  schema["properties"] = .object(properties)
  return KindDescriptor(descriptor.name, inputSchema: .object(schema), resultSchema: descriptor.resultSchema, inputChannels: descriptor.inputChannels, outputChannels: descriptor.outputChannels, deliveryPolicy: descriptor.deliveryPolicy)
}

/// What agents before search.v1 advertised instead.
private let oldSearchKinds = ["find.v1", "grep.v1"].map { KindDescriptor($0, inputSchema: ["type": "object"], resultSchema: ["type": "object"]) }

private struct CapabilityKind: OperationKind {
  typealias Input = JSONValue
  let descriptor: KindDescriptor
  func run(_ input: JSONValue, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    if descriptor.name == "search.v1" {
      if input.object?["pattern"] == "[" { throw OperationError(.invalidInput, message: "invalid pattern: [", details: ["search": "invalidPattern"]) }
      return ["hits": [["path": "/fixture", "line": 1, "text": "match"]], "cursor": "s2.next", "scanned": 1, "skipped": [["reason": "binary", "count": 1, "example": "/bin"]]]
    }
    return ["name": "fixture", "kind": "file", "size": 1, "token": "opaque", "mtime": 0]
  }
}

private final class PostCount: Sendable {
  let value = Mutex(0)
}

private func capabilityClient(_ descriptors: [KindDescriptor], posts: PostCount) throws -> MachineOperations {
  let agent = try OperationAgent(machine: "disk", kinds: descriptors.map { .init(CapabilityKind(descriptor: $0)) }, authorize: { _, _ in })
  return try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: FetchClient { request in
    if request.method == .post { posts.value.withLock { $0 += 1 } }
    let response = try await agent.handler(request)
    if request.method == .post, let id = UUID(uuidString: request.url.lastPathComponent) { await agent.execute(id) }
    return response
  }, store: MemoryOperationStore())
}

@Suite struct CapabilityCompatibilityTests {
  @Test func dev119MissingFilesystemKindsRefuseBeforePost() async throws {
    let posts = PostCount()
    let client = try capabilityClient([ComputerKindSchemas.exec, ComputerKindSchemas.read] + oldSearchKinds, posts: posts)
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

  @Test(arguments: [true, false]) func agentWithoutSearchV1RefusesBeforePost(old: Bool) async throws {
    let posts = PostCount()
    let client = try capabilityClient(old ? [ComputerKindSchemas.exec, ComputerKindSchemas.read] + oldSearchKinds : [], posts: posts)
    do {
      _ = try await client.search(machine: "disk", query: .init(mode: .grep, pattern: "match", root: "/", scope: "test"))
      Issue.record("Expected old search capability refusal")
    } catch let error as OperationError {
      #expect(error.code == .kindUnavailable)
      #expect(error.message.contains("search.v1"))
      #expect(error.message.contains("agent too old, upgrade"))
      #expect(error.details == ["kind": "search.v1", "reason": "agentTooOld", "started": false])
    }
    #expect(posts.value.withLock { $0 } == 0)
    await client.shutdown()
  }

  @Test func searchV1ReturnsThePageAndTypesItsErrors() async throws {
    let posts = PostCount()
    let client = try capabilityClient([ComputerKindSchemas.search], posts: posts)
    let page = try await client.search(machine: "disk", query: .init(mode: .grep, pattern: "match", root: "/", scope: "test"))
    #expect(page == SearchPage(hits: [.init(path: "/fixture", line: 1, text: "match")], cursor: "s2.next", scanned: 1, skipped: [.init(reason: .binary, count: 1, example: "/bin")]))
    let error = await #expect(throws: SearchError.self) { try await client.search(machine: "disk", query: .init(mode: .grep, pattern: "[", root: "/", scope: "test")) }
    #expect(error == SearchError(.invalidPattern, "invalid pattern: ["))
    #expect(posts.value.withLock { $0 } == 2)
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
    let client = try capabilityClient([withoutInput(ComputerKindSchemas.remove, removing: ["ifMatch"])], posts: posts)
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
    _ = try await client.open(.init(scope: "compatibility", key: "probe"), machine: "disk", start: .init(kind: "probe.v1", input: ["path": "/fixture", "future": true]))
    #expect(posts.value.withLock { $0 } == 1)
    await client.shutdown()
  }
}
