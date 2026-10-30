import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum InferenceKit.CatalogError
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import SpaceTools

extension Hub {
  // One creation path for create_session, wuhu:session and a page. A replay of the same (caller, call id) returns the first
  // session. It clones the template only if the first call never finished
  // cloning it, and hands over the message only if it was never handed over,
  // so a retry finishes a half-made session or fails the same way again.
  nonisolated public func createSession(
    _ caller: Caller,
    _ callID: ToolCallID,
    _ arguments: CreateSessionArguments,
  ) async throws -> ToolResultPayload {
    let spawned: Spawned
    do {
      spawned = try await spawn(caller, callID, arguments)
    } catch let problem as ToolProblem {
      throw ToolProblem("create_session: \(problem.message)", code: problem.code)
    }
    if let unfinished = spawned.unfinished {
      throw IncompleteSession(id: spawned.id, message: "create_session: session \(spawned.id.rawValue) was created, but \(unfinished)")
    }
    return .createSession(.init(
      sessionID: spawned.id, title: spawned.title, requestID: spawned.requestID, existing: spawned.existing ? true : nil,
      modelGroup: spawned.modelGroup, member: spawned.member, provider: spawned.provider, model: spawned.model,
    ))
  }

  nonisolated private func spawn(_ caller: Caller, _ callID: ToolCallID, _ order: CreateSessionArguments) async throws -> Spawned {
    let expectsReply = order.expectsReply ?? false
    guard !expectsReply || order.message != nil else {
      throw ToolProblem("expects_reply wants a message: it is create plus one request")
    }
    guard expectsReply || order.stallSeconds == nil else {
      throw ToolProblem("stall_seconds needs expects_reply: it belongs to the request")
    }
    let terms = try order.request?.terms() ?? .none
    guard expectsReply || terms == .none else {
      throw ToolProblem("request needs expects_reply: it describes the request")
    }
    let stall = try stallSeconds(order.stallSeconds)
    let title: String
    // The creating session's record; a person's sessions are all top-level.
    let creator: SessionRecord?
    let principal: Principal
    do {
      title = try SessionStore.usableTitle(order.title)
      switch caller {
      case let .session(id):
        let record = try await store.record(id)
        creator = record
        principal = Principal(actor: .session(id), group: record.group)
      case let .person(person):
        try await admit(person)
        creator = nil
        principal = person.principal
      case let .observer(observer):
        creator = nil
        principal = observer.principal
      }
    } catch let error as SessionStoreError {
      throw problem(error)
    }
    let topLevel = creator == nil || order.topLevel == true
    let parent = topLevel ? nil : creator?.id
    let recorded = try await store.receipt(caller, toolCallID: callID)
    let replayed = recorded != nil
    // A replay finishes its own create below; another call with a taken key
    // answers the session that holds it.
    if !replayed, let existing = try await store.keyedRequest(by: caller, terms) {
      return try await existingSpawn(existing)
    }
    var params = SessionCreationParams(
      executor: order.executor,
      modelGroup: order.modelGroup,
      provider: order.provider,
      model: order.model,
      effort: order.effort,
      tags: order.tags,
    )
    let kind: SessionKind
    let executor: SessionExecutor
    var template: SessionTemplate?
    do {
      if let name = order.template {
        let resolved = try await space.sessionTemplate(named: name, in: principal.group)
        params = params.merged(over: resolved.params)
        template = resolved
      }
      kind = try order.kind.map(sessionKind) ?? template?.kind ?? (topLevel ? .agent : .task)
      if order.group != nil, !topLevel {
        throw ToolProblem("only a top-level agent takes group; a child lives in its creator's group")
      }
      if topLevel {
        if let creator, creator.kind != .agent {
          throw ToolProblem("only an agent may create a top-level session; a task creates children only")
        }
        guard kind == .agent else {
          throw creator == nil
            ? ToolProblem("a person creates agents only; a task is created by its parent session", code: "taskInput")
            : ToolProblem("a top-level session is an agent; kind task is refused")
        }
        guard !expectsReply || creator == nil else {
          throw ToolProblem("a top-level session has no parent to report to; expects_reply is refused")
        }
      }
      if case let .createSession(first)? = recorded {
        executor = try await store.record(first.sessionID).executor
      } else {
        guard let resolveModelExecutor else {
          throw ToolProblem("creating sessions is not available on this server")
        }
        if let creator { params = params.merged(over: try await callerDefaults(creator.id, params: params)) }
        executor = try await SessionExecutor.resolve(params, resolveModelExecutor: resolveModelExecutor, resolveModelGroup: resolveModelGroup)
      }
    } catch let problem as ToolProblem {
      throw problem
    } catch let error as ExecutorUnavailableError {
      throw error
    } catch let error as ExecutorSpecError {
      throw ToolProblem(error.message, code: "invalidArgument")
    } catch let error as CatalogError {
      throw ToolProblem(error.description, code: error.code)
    } catch {
      throw ToolProblem("\(error)")
    }
    let group: GroupID
    do {
      let requested: GroupID?
      if let spelling = order.group {
        guard let resolved = try await space.resolveGroup(spelling) else { throw SpaceError.notFound(spelling) }
        requested = resolved
      } else { requested = nil }
      if case let .person(person) = caller, let requested, requested != person.group {
        throw outsidePageGroup(person.group, "creates sessions")
      }
      group = try await space.homeGroup(requested, creator: principal)
    } catch let error as SpaceError {
      if case .groupForbidden = error { throw ToolProblem(renderedFailure(Wire.failure(error)), code: "groupForbidden") }
      throw ToolProblem(renderedFailure(Wire.failure(error)))
    }
    let cloneOwed: Bool = if case let .createSession(first)? = recorded {
      first.cloneOwed == true
    } else {
      !replayed && template != nil
    }
    let messageID = MessageID(UUID.deterministic("request", caller.receiptHolder, callID.rawValue).uuidString.lowercased())
    // A child answers its parent; a person's agent answers the person.
    let requester: Caller = parent.map(Caller.session) ?? caller
    let id: SessionID
    do {
      let route: SessionModelRoute?
      if case let .createSession(first)? = recorded {
        route = try await store.modelRoute(first.sessionID)
      } else {
        route = try await prepareModelRoute?(executor, .create)
      }
      id = try await store.createSession(
        group: group,
        title: title,
        kind: kind,
        parent: parent,
        tags: params.tags ?? [],
        createdBy: caller.name,
        executor: executor,
        snapshot: .init(),
        receipt: (holder: caller, callID: callID),
        cloneOwed: template != nil,
        modelRoute: route,
        request: expectsReply ? (RequestID(messageID.rawValue), requester, order.message!, terms) : nil,
        observer: caller.observer,
      )
    } catch let refusal as ObserverRefusal {
      throw ToolProblem(refusal.description, code: refusal.code)
    } catch let taken as RequestKeyTaken {
      return try await existingSpawn((taken.existing, try await store.keyedRequest(by: caller, terms)!.task))
    } catch let foreign as ForeignReceipt {
      throw ToolProblem(
        "tool call \(foreign.toolCallID.rawValue) already holds a receipt from another tool; no session was created",
      )
    } catch let error as SessionStoreError {
      throw problem(error)
    } catch let error as CatalogError {
      throw ToolProblem(error.description, code: error.code)
    }
    var spawned = Spawned(id: id, title: title)
    do {
      if let template, cloneOwed {
        try await space.applySessionTemplate(template, to: id)
        try await store.settleClone(caller, toolCallID: callID)
      }
      if let message = order.message {
        if expectsReply {
          let delivery = try await store.openRequest(on: id, from: requester, messageID: messageID, text: message, deadline: nil, stallSeconds: stall, terms: terms)
          spawned.requestID = delivery.message.requestID
        } else if try await store.message(messageID) == nil {
          // A session primes the new one in private; a person has only its box.
          let target: ConversationTarget = creator == nil ? .box(id) : .dm(with: id.rawValue)
          _ = try await deliver(target, as: caller, messageID: messageID, text: message, replyTarget: nil, uploads: [])
        }
      }
      // A replay answers what the first call made, request included.
      if replayed, spawned.requestID == nil {
        spawned.requestID = try await store.message(messageID)?.requestID
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let problem as ToolProblem {
      spawned.unfinished = problem.message
    } catch let error as SessionStoreError {
      spawned.unfinished = problem(error).message
    } catch {
      spawned.unfinished = renderedFailure(Wire.failure(error))
    }
    if case let .modelGroup(group, _) = try await store.record(id).executor {
      spawned.modelGroup = group
      if let route = try await store.modelRoute(id) {
        spawned.member = route.member
        spawned.provider = route.specifier.provider
        spawned.model = route.specifier.model
      }
    }
    return spawned
  }

  // The session a taken key names. Its request not yet posted means the call
  // that made it never finished; only that call's retry can.
  nonisolated private func existingSpawn(_ existing: (request: RequestID, task: SessionID)) async throws -> Spawned {
    var spawned = Spawned(id: existing.task, title: try await store.record(existing.task).title, requestID: existing.request)
    spawned.existing = true
    if try await store.message(MessageID(existing.request.rawValue)) == nil {
      spawned.unfinished = "its request \(existing.request.rawValue) was never handed over; retry the call that created it"
    }
    return spawned
  }

  nonisolated private func sessionKind(_ raw: String) throws -> SessionKind {
    guard let kind = SessionKind(rawValue: raw) else {
      throw ToolProblem("kind is task or agent; got \(raw)")
    }
    return kind
  }
}

// The session a creation made; `unfinished` says what failed after it existed
// (its template not cloned, its message not handed over).
private struct Spawned {
  var id: SessionID
  var title: String
  var requestID: RequestID?
  var existing = false
  var modelGroup: String?
  var member: String?
  var provider: String?
  var model: String?
  var unfinished: String?
}

// A page borrows its viewer's rights, so it acts only inside its own group.
extension Hub {
  // A page acts with its viewer's authority, and only where the viewer writes
  // the page's group.
  nonisolated func admit(_ person: Person) async throws {
    if let account = person.account, try await space.isGuest(account) {
      throw ToolProblem("a guest's page creates no sessions and posts no messages", code: "groupForbidden")
    }
    guard try await space.writableGroups(for: person.principal).contains(person.group) else {
      throw ToolProblem("the viewer does not write group \(person.group.rawValue)", code: "groupForbidden")
    }
  }
}

func outsidePageGroup(_ group: GroupID, _ verb: String) -> ToolProblem {
  ToolProblem("a page or an observer \(verb) only in its own group \(group.rawValue)", code: "outsidePageGroup")
}
