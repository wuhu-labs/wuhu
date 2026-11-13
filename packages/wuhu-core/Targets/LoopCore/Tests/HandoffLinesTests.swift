#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct HandoffLinesTests {
  @Test func replayBoundaryCarriesOnlyAPortableRecentTailAndPointer() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let binding = ReplayBinding(identity: "new-account", epoch: "new-epoch")
      let script = InferenceScript([
        { _ in
          var reply = Fix.reply("reading", calls: [.init(id: "provider-call", name: "read", arguments: .object([:]))])
          reply.message.content.insert(.reasoning(.encrypted(.init(providerID: "old", model: "m", summary: "readable reasoning", opaque: "private-signature", replayScope: "old-account"))), at: 0)
          return reply
        },
        Fix.replying("ready"),
        { _ in throw ReplayBoundaryRequired(binding: binding) },
        { request in
          #expect(request.generation == 1)
          #expect(request.binding == binding)
          #expect(request.lines.allSatisfy { $0.meta == nil })
          #expect(request.lines.contains { $0.key == "head:summary" && $0.text.contains("/0.outline.txt") })
          #expect(request.lines.contains { $0.key == "subscription:replay-handoff" })
          #expect(request.lines.contains { $0.text.contains("readable reasoning") })
          #expect(!request.lines.contains { $0.key == "message:m1" })
          #expect(request.lines.contains { $0.key == "message:m2" && $0.text.hasSuffix("\n\ncontinue") })
          let receipt = try #require(request.lines.compactMap { line -> ToolResultMessage? in
            if case let .toolResult(result) = line.message { result } else { nil }
          }.first)
          #expect(request.lines.toolCall(.init(receipt.toolCallId)) != nil)
          let encoded = String(decoding: try JSONEncoder().encode(request.lines), as: UTF8.self)
          #expect(!encoded.contains("private-signature"))
          #expect(!encoded.contains("old-account"))
          return Fix.reply("continued")
        },
      ])
      let config = makeConfig(executeTool: { _ in .read(.init(path: "/a", revision: .journal(1), content: "receipt")) }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await space.sessions.createSession(group: .shared, title: "handoff", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message(String(repeating: "old context ", count: 4000)), to: id)
        try await until("the original tool turn settles") { try await space.sessions.settledWork(id) && script.count == 2 }
        try await service.enqueue(item: Fix.message("continue", message: "m2"), to: id)
        try await until("the portable generation settles") { try await space.sessions.settledWork(id) && script.count == 4 }
        #expect(try await space.sessions.generation(id) == 1)
        #expect(try await space.sessions.transcriptLines(id, generation: 0).contains { $0.meta != nil })
      }
    }
  }

  @Test(arguments: [(replacement: false, carriesTail: true), (replacement: true, carriesTail: true), (replacement: true, carriesTail: false)])
  func compactionStripsCarriedAccountContentOnlyForAReplacementBinding(replacement: Bool, carriesTail: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let old = SessionModelRoute(group: nil, member: nil, specifier: .test, bindingFingerprint: "old", epoch: "old", reason: .create, placedAt: anchor, evidence: [])
      let script = InferenceScript([
        Fix.replying("marking", calls: [.init(id: "bookmark", name: "bookmark", arguments: .object(["name": .string("keep")]))]),
        { _ in
          var reply = Fix.reply("reading", calls: [.init(id: "read", name: "read", arguments: .object([:]))])
          reply.message.content.insert(.reasoning(.encrypted(.init(providerID: "old", model: "m", summary: "readable reasoning", opaque: "private-signature", replayScope: "old-account"))), at: 0)
          return reply
        },
        Fix.replying("folding", calls: [.init(id: "compact", name: "compact", arguments: .object(["summary": .string("folded"), "bookmark": .string("keep")]))]),
        { request in
          #expect(request.generation == 1)
          let encoded = String(decoding: try JSONEncoder().encode(request.lines), as: UTF8.self)
          #expect(encoded.contains("private-signature") == (!replacement && carriesTail))
          #expect(encoded.contains("readable reasoning") == carriesTail)
          #expect(request.lines.allSatisfy { $0.meta == nil })
          return Fix.reply("continued")
        },
      ])
      var config = makeConfig(executeTool: { _ in .read(.init(path: "/a", revision: .journal(1), content: "receipt")) }, inference: { try await script($0) })
      config.prepareCompaction = { _, _, _ in
        var next = old
        next.specifier.effort = "low"
        if replacement { next.epoch = "new" }
        return ModelRouteTransition(expectedEpoch: old.epoch, route: next, binding: replacement ? .init(identity: "new-account", epoch: "new") : nil, carriesTail: carriesTail)
      }
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await space.sessions.createSession(group: .shared, title: "placement carry", kind: .agent, createdBy: "morgan", executor: .kernel(.test), modelRoute: old)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("the placement carries its selected line form") { try await space.sessions.settledWork(id) && script.count == 4 }
      }
    }
  }
}
