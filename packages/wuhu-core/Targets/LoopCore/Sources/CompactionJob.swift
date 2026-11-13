import SessionDomain
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// One compaction gathers the next generation's head and the positions to carry; its session cell writes them. A restart computes it again.
@Job
struct CompactionJob {
  struct Params: Codable {
    let session: SessionID
    let generation: Int
    let position: Int
    let kind: Kind
  }

  enum Kind: Codable {
    case fold(ToolCallID)
    case pointer
    case legacy
    case handoff(ReplayBinding)
  }

  typealias Message = Never

  mutating func start() async throws -> Outcome {
    let client = ctx.dependency(LoopClient.self)
    let params = ctx.params
    switch params.kind {
    case .legacy:
      break
    case .fold, .pointer, .handoff:
      if try await ctx.effect({ try await client.store.isLegacy(params.session, generation: params.generation) }) {
        return .done(sending: .look, to: SessionCell.ID(params.session.rawValue).recipient)
      }
    }
    guard let turn = ctx.cell(SessionCell.ID(params.session.rawValue)).turn() else { preconditionFailure("compaction requires a turn row") }
    let bookmarks = turn.bookmarks ?? [:]
    let answer = try await ctx.effect { try await compaction(params, client, bookmarks: bookmarks) }
    return .done(sending: .compacted(id, answer), to: SessionCell.ID(params.session.rawValue).recipient)
  }

  private func compaction(_ params: Params, _ client: LoopClient, bookmarks: [String: Int]) async throws -> CompactionAnswer {
    do {
      let stored = try await client.store.transcriptLines(params.session, generation: params.generation)
      let lines = try stored.map { try $0.line() }
      switch params.kind {
      case let .fold(callID):
        guard let compact = lines.toolCall(callID) else { preconditionFailure("compact tool call \(callID.rawValue) is not in the generation's lines") }
        let arguments = try decodeArguments(CompactArguments.self, from: compact.call)
        let kept: Range<Int>?
        if let name = arguments.bookmark {
          guard let position = bookmarks[name] else { preconditionFailure("compact bookmark \(name) was validated by the cell") }
          guard let marker = stored.firstIndex(where: { $0.position == position }) else { preconditionFailure("bookmark position \(position) has no line") }
          precondition(marker < compact.index, "compact bookmark precedes the reply holding the compact call")
          kept = lines.keptRange(after: marker, upTo: compact.index).map { stored[$0.lowerBound].position ..< stored[$0.upperBound].position }
        } else {
          kept = nil
        }
        let head = GenerationHead(
          id: client.uuid(), timestamp: client.now(), summary: arguments.summary,
          snapshot: .init(preReads: arguments.preReads ?? []),
          runningWork: try await client.runningWork(params.session), awaiting: client.store.awaitedRequests(params.session),
        )
        let budget = await client.budget(params.session)
        let carried = try stored.filter { kept?.contains($0.position) == true && $0.key != LineKey.pressure }
          .compactMap { try $0.line().carried(portable: false) }
        let tokenEstimate = (head.lines(session: params.session) + carried).estimatedContextTokens(images: budget.images)
        let transition: ModelRouteTransition?
        do {
          transition = try await client.prepareCompaction(params.session, tokenEstimate, arguments.target)
        } catch let refusal where arguments.target != nil && !(refusal is CancellationError) {
          return .refused(callID, "compact target \"\(arguments.target!.model)\" refused, nothing was folded: \(refusal)")
        }
        return .folded(head: head, kept: transition?.carriesTail == false ? nil : kept, transition: transition, call: callID)
      case .pointer, .legacy:
        let summary: String
        if case .legacy = params.kind {
          summary = "The server now stores transcript lines instead of typed items. This session's earlier context was not converted, so this generation starts without a summary. Read the old items with SELECT generation, position, kind, payload FROM session_legacy_items WHERE session_id = '\(params.session.rawValue)' ORDER BY generation, position; then pick up the outstanding work."
        } else {
          summary = SessionPrompt.pointerSummary(session: params.session, generation: params.generation)
        }
        let head = GenerationHead(
          id: client.uuid(), timestamp: client.now(), summary: summary, snapshot: .init(),
          runningWork: try await client.runningWork(params.session), awaiting: client.store.awaitedRequests(params.session),
        )
        let budget = await client.budget(params.session)
        let transition = try await client.prepareCompaction(params.session, head.lines(session: params.session).estimatedContextTokens(images: budget.images), nil)
        return .folded(head: head, kept: nil, transition: transition, call: nil)
      case let .handoff(binding):
        let budget = await client.budget(params.session)
        let head = GenerationHead(
          id: client.uuid(), timestamp: client.now(), summary: SessionPrompt.pointerSummary(session: params.session, generation: params.generation),
          snapshot: .init(), replayBinding: binding,
          runningWork: try await client.runningWork(params.session), awaiting: client.store.awaitedRequests(params.session),
        )
        let after = TranscriptItem.notification(SystemNotification(
          id: client.uuid(), timestamp: client.now(), kind: .context, subscriptionID: SubscriptionID("replay-handoff"),
          content: .init(text: "Portable replay handoff completed. Earlier tool calls remain recorded in the carried transcript; do not execute them again. This is a fresh account-neutral turn. Continue the outstanding request using the carried context; re-read files/history as needed."),
        )).lines(session: params.session)
        let tail = try stored.filter { !$0.key.hasPrefix(LineKey.head) && $0.key != LineKey.pressure }.compactMap { stored in
          try stored.line().carried(portable: true).map { (position: stored.position, line: $0) }
        }
        let portable = tail.map(\.line)
        let start = portable.recentTail(tokens: 8192, images: budget.images)
        let kept = start.map { tail[$0].position ..< (tail[tail.count - 1].position + 1) }
        return .handoff(head: head, kept: kept, binding: binding, after: after)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failed(String(describing: error))
    }
  }
}

enum CompactionAnswer: Sendable, Codable {
  case folded(head: GenerationHead, kept: Range<Int>?, transition: ModelRouteTransition?, call: ToolCallID?)
  case refused(ToolCallID, String)
  case handoff(head: GenerationHead, kept: Range<Int>?, binding: ReplayBinding, after: [TranscriptLine])
  case failed(String)
}
