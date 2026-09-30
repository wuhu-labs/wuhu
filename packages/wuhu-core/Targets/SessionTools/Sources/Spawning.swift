import Dependencies
import Foundation
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import SpaceTools

// The operator verbs a session may apply to itself and its descendants, and,
// for archive and unarchive, to a session it created and, as a top-level
// agent, to any session of its group. The session loops live above this
// target, so the server hands them in.
public struct SessionControl: Sendable {
  public enum Verb: String, Sendable, CaseIterable {
    case interrupt
    case resume
    case archive
    case unarchive
  }

  public var perform: @Sendable (Verb, SessionID, Bool) async throws -> Void

  public init(perform: @escaping @Sendable (Verb, SessionID, Bool) async throws -> Void) {
    self.perform = perform
  }
}

// A verb the session loop refused, with the reason a caller can read.
public struct SessionControlRefusal: Error {
  public enum Reason: Sendable {
    case busy
    case other
  }

  public var message: String
  public var reason: Reason

  public init(_ message: String, reason: Reason = .other) {
    self.message = message
    self.reason = reason
  }
}

struct SpawnOrder {
  var title: String
  var kind: String?
  var topLevel = false
  var group: String?
  var provider: String?
  var model: String?
  var effort: String?
  var tags: [String]?
  var template: String?
  var expectsReply = false
  var message: String?
}

struct Spawned {
  var id: SessionID
  var title: String
  var requestID: RequestID?
  // Set when the session exists but cloning its template or handing it the
  // message failed: the caller still learns the id.
  var unfinished: String?
}

extension ToolExecutor {
  // One creation path for create_session and wuhu:session. A replay of the
  // same (caller, call id) returns the first session. It clones the template
  // only if the first call never finished cloning it, and hands over the
  // message only if it was never handed over, so a retry finishes a half-made
  // session or fails the same way again.
  func spawn(_ caller: SessionID, _ callID: ToolCallID, _ order: SpawnOrder) async throws -> Spawned {
    guard let resolveModelExecutor else {
      throw ToolProblem("creating sessions is not available on this server")
    }
    guard !order.expectsReply || order.message != nil else {
      throw ToolProblem("expects_reply wants a message: it is create plus one request")
    }
    let title: String
    let creator: SessionRecord
    do {
      title = try SessionStore.usableTitle(order.title)
      creator = try await store.record(caller)
    } catch let error as SessionStoreError {
      throw problem(error)
    }
    var params = SessionCreationParams(
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
        let resolved = try await space.sessionTemplate(named: name, in: creator.group)
        params = params.merged(over: resolved.params)
        template = resolved
      }
      kind = try order.kind.map(sessionKind) ?? template?.kind ?? (order.topLevel ? .agent : .task)
      if order.group != nil, !order.topLevel {
        throw ToolProblem("only a top-level agent takes group; a child lives in its creator's group")
      }
      if order.topLevel {
        guard creator.kind == .agent else {
          throw ToolProblem("only an agent may create a top-level session; a task creates children only")
        }
        guard kind == .agent else {
          throw ToolProblem("a top-level session is an agent; kind task is refused")
        }
        guard !order.expectsReply else {
          throw ToolProblem("a top-level session has no parent to report to; expects_reply is refused")
        }
      }
      params = params.merged(over: try await callerDefaults(caller, provider: params.provider))
      executor = try await SessionExecutor.resolve(params, resolveModelExecutor: resolveModelExecutor)
    } catch let problem as ToolProblem {
      throw problem
    } catch let error as ExecutorSpecError {
      throw ToolProblem(error.message)
    } catch {
      throw ToolProblem("\(error)")
    }
    let group: GroupID
    do {
      group = try await space.homeGroup(order.group.map(GroupID.init(rawValue:)), creator: creator.group)
    } catch let error as SpaceError {
      throw ToolProblem(renderedFailure(Wire.failure(error)))
    }
    let recorded = try await store.receipt(caller, toolCallID: callID)
    let replayed = recorded != nil
    let cloneOwed: Bool = if case let .createSession(first)? = recorded {
      first.cloneOwed == true
    } else {
      !replayed && template != nil
    }
    let id: SessionID
    do {
      id = try await store.createSession(
        group: group,
        title: title,
        kind: kind,
        parent: order.topLevel ? nil : caller,
        tags: params.tags ?? [],
        createdBy: caller.rawValue,
        executor: executor,
        snapshot: .init(),
        receipt: (session: caller, callID: callID),
        cloneOwed: template != nil,
      )
    } catch let foreign as ForeignReceipt {
      throw ToolProblem(
        "tool call \(foreign.toolCallID.rawValue) already holds a receipt from another tool; no session was created",
      )
    } catch let error as SessionStoreError {
      throw problem(error)
    }
    var spawned = Spawned(id: id, title: title)
    let messageID = MessageID(UUID.deterministic("request", caller.rawValue, callID.rawValue).uuidString.lowercased())
    do {
      if let template, cloneOwed {
        try await space.applySessionTemplate(template, to: id)
        try await store.settleClone(caller, toolCallID: callID)
      }
      if let message = order.message {
        if order.expectsReply {
          let delivery = try await store.openRequest(on: id, from: caller, messageID: messageID, text: message, deadline: nil)
          spawned.requestID = delivery.message.requestID
        } else if try await store.message(messageID) == nil {
          _ = try await deliver(
            .dm(with: id.rawValue), session: caller, messageID: messageID, text: message, replyTarget: nil, uploads: [],
          )
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
    return spawned
  }

  private func sessionKind(_ raw: String) throws -> SessionKind {
    guard let kind = SessionKind(rawValue: raw) else {
      throw ToolProblem("kind is task or agent; got \(raw)")
    }
    return kind
  }

  // In charge means the session itself or any ancestor, checked when the
  // call runs, so a session archived meanwhile has lost the right.
  func refuseUnlessInCharge(_ caller: SessionID, of target: SessionID) async throws {
    do {
      try await refuseUnlessLive(caller)
      try await store.refuseControl(of: target, by: caller)
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }

  // Archive and unarchive also admit the creator of a top-level
  // session and any admin of the target's group.
  func refuseUnlessMayArchive(_ caller: SessionID, of target: SessionID) async throws {
    do {
      try await refuseUnlessLive(caller)
      try await store.refuseArchiving(target, by: .session(caller))
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }

  func refuseUnlessLive(_ caller: SessionID) async throws {
    do {
      guard case .live = try await store.record(caller).lifecycle else {
        throw ToolProblem("session \(caller.rawValue) is archived and may no longer act on sessions")
      }
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }

  func setTags(_ caller: SessionID, of target: SessionID, to tags: [String]) async throws {
    try await refuseUnlessInCharge(caller, of: target)
    do {
      try await store.setTags(target, to: tags)
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }

  func control(_ verb: SessionControl.Verb, _ caller: SessionID, of target: SessionID, force: Bool = false) async throws {
    guard let control else {
      throw ToolProblem("\(verb.rawValue) is not available on this server")
    }
    switch verb {
    case .archive, .unarchive:
      try await refuseUnlessMayArchive(caller, of: target)
    case .interrupt, .resume:
      try await refuseUnlessInCharge(caller, of: target)
    }
    if verb == .archive, force, caller == target {
      throw ToolProblem("session \(target.rawValue) can't force-archive itself; its parent, an ancestor or a human archives it")
    }
    do {
      try await control.perform(verb, target, force)
    } catch let refusal as SessionControlRefusal {
      if refusal.reason == .busy, verb == .archive, caller == target {
        throw ToolProblem("session \(target.rawValue) can't archive itself mid-turn: this call is part of its own turn, which keeps it busy; its parent, an ancestor or a human archives it; \(refusal.message)")
      }
      throw ToolProblem(refusal.message)
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }
}
