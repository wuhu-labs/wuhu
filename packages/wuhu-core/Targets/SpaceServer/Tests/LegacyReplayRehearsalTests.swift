import Dependencies
import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

private struct OfflineRehearsalMedia: MediaResolver {
  func resolve(_ media: MediaContent) async throws -> ResolvedMedia? {
    .text("Attachment reference retained; media bytes are not loaded in this offline rehearsal.")
  }
}

@Suite struct LegacyReplayRehearsalTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["WUHU_REPLAY_REHEARSAL_DB"] != nil))
  func oldLiveTranscriptIsAdoptedOnceWithoutSendingOpacity() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["WUHU_REPLAY_REHEARSAL_DB"])
    let ids = try #require(ProcessInfo.processInfo.environment["WUHU_REPLAY_REHEARSAL_SESSIONS"]).split(separator: ",").map { SessionID(String($0)) }
    try await withSessionDeps {
      let space = try Space.open(file: URL(fileURLWithPath: path))
      for (index, id) in ids.enumerated() {
        guard case let .kernel(original) = try await space.sessions.hydrate(id).transcript else {
          Issue.record("rehearsal requires kernel transcript")
          return
        }
        let before = try await space.sessions.generationState(id).generation
        let opaque = original.items.flatMap { item -> [String] in
          guard case let .assistant(entry) = item else { return [] }
          return entry.content.compactMap { block in
            guard case let .reasoning(.encrypted(content)) = block, !content.opaque.isEmpty else { return nil }
            return content.opaque
          }
        }
        let binding = ReplayBinding(identity: "offline-rehearsal-\(index)", epoch: "offline-route-1")
        #expect(!opaque.isEmpty)
        #expect(original.requiresReplayHandoff(to: binding.identity))
        #expect(original.pendingToolCallIDs.isEmpty)
        let portable = try original.portableHandoff(binding: binding, budget: .init(maxInput: 1_000_000, maxOutput: 1000))
        _ = try await space.sessions.writePortableHandoff(id, expectedGeneration: before, source: original, transcript: portable)
        let reopened = try Space.open(file: URL(fileURLWithPath: path))
        guard case let .kernel(adopted) = try await reopened.sessions.hydrate(id).transcript else {
          Issue.record("adopted rehearsal requires kernel transcript")
          return
        }
        let after = try await reopened.sessions.generationState(id).generation
        #expect(after == before + 1)
        #expect(!adopted.requiresReplayHandoff(to: binding.identity))
        #expect(!adopted.hasUnscopedReplay)
        #expect(adopted.replayBinding == binding)
        #expect(adopted.pendingToolCallIDs.isEmpty)
        #expect(adopted.environment.settle == original.environment.settle)
        let lastAssistant = original.items.lastIndex { if case .assistant = $0 { return true }; return false }
        let lastCalls = lastAssistant.map { index -> Set<ToolCallID> in
          guard case let .assistant(entry) = original.items[index] else { return [] }
          return Set(entry.toolCalls.map { ToolCallID($0.id) })
        } ?? []
        let latestReceipts = original.items.filter { item in
          guard case let .toolResult(result) = item, case let .toolCall(id) = result.provenance else { return false }
          return lastCalls.contains(id)
        }
        let receiptIDs = Set(latestReceipts.map(\.id))
        let retainedReceipts = Set(adopted.items.filter { receiptIDs.contains($0.id) }.map(\.id)) == receiptIDs
        #expect(retainedReceipts)
        let openRequestInputs = original.items.filter { item in
          guard case let .message(message) = item, let request = message.requestID else { return false }
          return original.environment.settle.openRequests[request] != nil
        }
        let requestIDs = Set(openRequestInputs.map(\.id))
        let retainedOpenInputs = Set(adopted.items.filter { requestIDs.contains($0.id) }.map(\.id)) == requestIDs
        #expect(retainedOpenInputs)
        let bodies = Mutex<[String]>([])
        let fake = FetchClient { request in
          let body = String(decoding: try await request.body?.data() ?? Data(), as: UTF8.self)
          bodies.withLock { $0.append(body) }
          return Response(status: .unauthorized, body: .bytes(Data("Offline replay rehearsal: no upstream called.".utf8), contentType: "text/plain"))
        }
        let endpoint: any ModelEndpoint = if index == 0 {
          AnthropicEndpoint(model: "claude-rehearsal", replayScope: binding.identity, routeEpoch: binding.epoch, baseURL: URL(string: "http://127.0.0.1:1")!, apiKey: "offline-fake-key").withFetch(fake)
        } else {
          OpenAICodexEndpoint(model: "codex-rehearsal", replayScope: binding.identity, routeEpoch: binding.epoch, baseURL: URL(string: "http://127.0.0.1:1")!, jwt: "offline-fake-token", chatgptAccountID: "offline-fake-account", sessionID: id.rawValue).withFetch(fake)
        }
        let context = await adopted.renderRequest(session: id, systemPrompt: "Offline replay rehearsal.")
        do {
          for try await _ in endpoint.inference(context: context, options: .init(reasoning: index == 0 ? .effort("high") : .none), mediaResolver: OfflineRehearsalMedia()).stream() {}
        } catch {}
        let emitted = bodies.withLock { $0 }
        #expect(emitted.count == 1)
        let noOldOpaqueBytes = emitted.allSatisfy { body in opaque.allSatisfy { !body.contains($0) } }
        #expect(noOldOpaqueBytes)
        let forbiddenFields = ["encrypted_content", "signature", "redacted_thinking", "web_search_call"]
        let noNativeReplay = emitted.allSatisfy { body in forbiddenFields.allSatisfy { !body.contains("\"\($0)\"") } }
        #expect(noNativeReplay)
        print("REPLAY_REHEARSAL case=\(index) generation=\(before)->\(after) opaque_before=\(opaque.count) opaque_after=0 binding_present=\(adopted.replayBinding != nil) requests=\(emitted.count) foreign_opaque=false native_reasoning_hosted=false boundary_repeats=false latest_receipts=\(latestReceipts.count) receipts_preserved=\(retainedReceipts) open_inputs=\(openRequestInputs.count) inputs_preserved=\(retainedOpenInputs)")
      }
    }
  }
}
