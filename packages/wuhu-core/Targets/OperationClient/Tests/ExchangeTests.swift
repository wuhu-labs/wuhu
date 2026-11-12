#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
@testable import OperationClient
import OperationProtocol
import Synchronization
import Testing
import Tracing

@Suite struct ExchangeTests {
  @Test func methodsPathsQueriesAndCorrelationAreOneDispatchEach() async throws {
    let wire = ExchangeFixture()
    let id = UUID(), correlation = UUID()
    _ = try await wire.send(.describe)
    _ = try await wire.send(.start(id), body: .json(StartRequest(kind: "read.v1", input: ["path": "/file"])), correlation: correlation)
    _ = try await wire.send(.poll(id, query: [.init(name: "channel", value: "data"), .init(name: "after", value: "17")]), correlation: correlation)
    _ = try await wire.send(.input(id, channel: "data"), body: .json(WriteRequest(offset: .zero, payload: .init(data: Data([1])), end: true)), correlation: correlation)
    _ = try await wire.send(.stop(id), body: .json(StopRequest(reason: "testStop")), correlation: correlation)
    let sent = wire.requests.value.withLock { $0 }
    #expect(sent.map(\.method) == [.get, .post, .get, .put, .put])
    let base = "/machine/v2/machines/disk"
    #expect(sent.map { $0.url.path } == [base, base + "/operations/\(id)", base + "/operations/\(id)", base + "/operations/\(id)/inputs/data", base + "/operations/\(id)/stop"])
    #expect(URLComponents(url: sent[2].url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "channel", value: "data"), .init(name: "after", value: "17")])
    let requestIDs = sent.compactMap { $0.headers["X-Wuhu-Request-ID"] }
    #expect(requestIDs.count == 5 && Set(requestIDs).count == 5)
    #expect(sent[0].headers["X-Wuhu-Correlation-ID"] == requestIDs[0])
    #expect(sent.dropFirst().allSatisfy { $0.headers["X-Wuhu-Correlation-ID"] == correlation.uuidString })
    await wire.link.taskScope.close()
  }

  @Test(arguments: ["X-Wuhu-Request-ID", "X-Wuhu-Correlation-ID", "X-Wuhu-Agent-Instance"])
  func invalidResponseIdentityIsNotAnAnswer(_ header: String) async throws {
    let link = MachineLink(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { request in
      var response = try ExchangeFixture.response(request)
      response.headers[.init(header)!] = "invalid"
      return response
    }, clock: .continuous, ids: { UUID() }, tracer: NoOpTracer())
    let exchanged = await link.send(JSONValue.self, "disk", .describe, correlation: nil, deadline: .seconds(5), limit: 1024)
    #expect(!exchanged.answered)
    let error = #expect(throws: OperationError.self) { try exchanged.result.get() }
    #expect(error?.code == .invalidResponse)
    await link.taskScope.close()
  }

  @Test(arguments: [OperationError.Code.kindUnavailable, .init(rawValue: "futureFailure")])
  func aTypedRefusalIsAnAnswerWithoutRetry(_ code: OperationError.Code) async throws {
    let calls = Mutex(0)
    let link = MachineLink(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { request in
      calls.withLock { $0 += 1 }
      var response = try ExchangeFixture.response(request)
      response.status = .badRequest
      response.body = try .json(ErrorEnvelope(.init(code)))
      return response
    }, clock: .continuous, ids: { UUID() }, tracer: NoOpTracer())
    let exchanged = await link.send(JSONValue.self, "disk", .describe, correlation: nil, deadline: .seconds(5), limit: 1024)
    #expect(exchanged.answered)
    let error = #expect(throws: OperationError.self) { try exchanged.result.get() }
    #expect(error?.code == code)
    #expect(calls.withLock { $0 } == 1)
    await link.taskScope.close()
  }

  @Test func invalidTypedBodyKeepsResponseEvidenceButMalformedErrorDoesNot() async throws {
    for refusal in [false, true] {
      let link = MachineLink(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { request in
        var response = try ExchangeFixture.response(request)
        if refusal { response.status = .badRequest }
        return response
      }, clock: .continuous, ids: { UUID() }, tracer: NoOpTracer())
      let exchanged = await link.send(MachineDescription.self, "disk", .describe, correlation: nil, deadline: .seconds(5), limit: 1024)
      #expect(exchanged.answered == !refusal)
      let error = #expect(throws: OperationError.self) { try exchanged.result.get() }
      #expect(error?.code == .invalidResponse)
      await link.taskScope.close()
    }
  }

  @Test func responseBodyLimitFailsWithoutRetry() async throws {
    let calls = Mutex(0)
    let link = MachineLink(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { request in
      calls.withLock { $0 += 1 }
      return try ExchangeFixture.response(request)
    }, clock: .continuous, ids: { UUID() }, tracer: NoOpTracer())
    let exchanged = await link.send(JSONValue.self, "disk", .describe, correlation: nil, deadline: .seconds(5), limit: 1)
    #expect(!exchanged.answered)
    #expect(throws: OperationError.self) { try exchanged.result.get() }
    #expect(calls.withLock { $0 } == 1)
    await link.taskScope.close()
  }
}
