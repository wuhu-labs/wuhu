import SessionDomain
import WuweiNeo
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// One compaction of the generation its id names, at `position`: what it needs from outside the session (running work, placement, the mechanical compactor, open requests) gathered into the next generation's head, which its session cell writes. A restart computes it again.
@Job
struct CompactionJob {
  struct Params: Codable {
    let session: SessionID
    let generation: Int
    let position: Int
    let kind: Kind
  }

  enum Kind: Codable {
    /// The model's `compact` call.
    case fold(ToolCallID)
    /// The mechanical compactor's, when the model's own compaction failed or the request does not fit.
    case fallback
    case handoff(ReplayBinding, ContextBudget)
  }

  typealias Message = Never

  mutating func start() async throws -> Outcome {
    let client = ctx.dependency(LoopClient.self)
    let params = ctx.params
    let answer = try await ctx.effect { try await compaction(params, client) }
    return .done(sending: .compacted(id, answer), to: SessionCell.ID(params.session.rawValue).recipient)
  }

  private func compaction(_ params: Params, _ client: LoopClient) async throws -> CompactionAnswer {
    let transcript = try await client.transcript(params.session, params.generation, params.position)
    let environment = transcript.environment
    do {
      switch params.kind {
      case let .fold(callID):
        let arguments = try decodeArguments(CompactArguments.self, from: transcript.compactCall(callID))
        let kept = try transcript.compactKeptRange(callID: callID, bookmark: arguments.bookmark)
        let head = GenerationHead(
          id: client.uuid(), timestamp: client.now(), summary: arguments.summary,
          snapshot: .init(carrying: environment.tools, arguments: arguments), settle: environment.settle,
          runningWork: try await client.runningWork(params.session), awaiting: try await client.store.awaitedRequests(params.session),
        )
        let transition: ModelRouteTransition?
        do {
          transition = try await client.prepareCompaction(params.session, transcript.compacted(head: head, kept: kept), arguments.target)
        } catch let refusal where arguments.target != nil && !(refusal is CancellationError) {
          return .refused(callID, "compact target \"\(arguments.target!.model)\" refused, nothing was folded: \(refusal)")
        }
        return .folded(head: head, kept: kept, transition: transition, call: callID)
      case .fallback:
        let outcome = try await client.compact(params.session, transcript)
        let head = GenerationHead(
          id: client.uuid(), timestamp: client.now(), summary: outcome.summary,
          snapshot: .init(subscriptions: environment.tools.subscriptions, preReads: outcome.preReads), settle: environment.settle,
          runningWork: try await client.runningWork(params.session), awaiting: try await client.store.awaitedRequests(params.session),
        )
        let transition = try await client.prepareCompaction(params.session, transcript.compacted(head: head, kept: outcome.kept), nil)
        return .folded(head: head, kept: outcome.kept, transition: transition, call: nil)
      case let .handoff(binding, budget):
        let openRequests = try await client.store.openRequests(params.session)
        let runningWork = try await client.runningWork(params.session)
        return try client.dependencies.yield {
          try .handoff(transcript.portableHandoff(binding: binding, budget: budget, runningWork: runningWork, openRequests: openRequests))
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failed(String(describing: error))
    }
  }
}

/// How a compaction ended, as the session cell writes it.
enum CompactionAnswer: Sendable, Codable {
  /// `call` is the model's `compact` call the fold closes, if it made one.
  case folded(head: GenerationHead, kept: Range<Int>?, transition: ModelRouteTransition?, call: ToolCallID?)
  case refused(ToolCallID, String)
  case handoff(Transcript)
  /// Terminal: the session is errored.
  case failed(String)
}
