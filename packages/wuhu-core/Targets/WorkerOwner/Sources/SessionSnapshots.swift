#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum SessionDomain.QueueInput
import enum SessionDomain.SessionExecutor
import struct SessionDomain.SessionID
import struct SessionDomain.Transcript
import enum SessionDomain.TranscriptItem
import struct SpaceContract.GroupID
import struct SpaceCore.CompactRequestClaim
import struct SpaceCore.QueueDrain
import enum SpaceCore.SessionCommand
import enum SpaceCore.SessionHold
import struct SpaceCore.SessionHydration
import enum SpaceCore.SessionKind
import enum SpaceCore.SessionLifecycle
import struct SpaceCore.SessionQueueEntry
import struct SpaceCore.SessionRecord
import struct SpaceCore.SessionRestart
import enum SpaceCore.SessionWork
import struct WorkerProtocol.WorkerProtocolError

struct RecordSnapshot: Codable, Sendable {
  let id: SessionID
  let kind: SessionKind
  let parent: SessionID?
  let title: String
  let tags: [String]
  let createdBy: String
  let executor: ExecutorSnapshot
  let createdAt: Date
  let lastActivityAt: Date
  let hold: String
  let work: String
  let errorMessage: String?
  let lifecycle: String
  let graceExpiresAt: Date?
  let group: GroupID

  init(_ record: SessionRecord) {
    id = record.id; kind = record.kind; parent = record.parent; title = record.title; tags = record.tags
    createdBy = record.createdBy; executor = .init(record.executor); createdAt = record.createdAt; lastActivityAt = record.lastActivityAt
    hold = record.hold.rawValue; work = record.work.rawValue; errorMessage = record.errorMessage; group = record.group
    switch record.lifecycle {
    case .live: lifecycle = "live"; graceExpiresAt = nil
    case let .archived(expiry): lifecycle = "archived"; graceExpiresAt = expiry
    }
  }

  func record() throws -> SessionRecord {
    guard let hold = SessionHold(rawValue: hold), let work = SessionWork(rawValue: work) else {
      throw WorkerProtocolError(.invalidMessage, message: "Unknown session snapshot state")
    }
    let lifecycle: SessionLifecycle
    switch (self.lifecycle, graceExpiresAt) {
    case ("live", nil): lifecycle = .live
    case ("archived", let expiry?): lifecycle = .archived(graceExpiresAt: expiry)
    default: throw WorkerProtocolError(.invalidMessage, message: "Invalid session snapshot lifecycle")
    }
    return SessionRecord(id: id, kind: kind, parent: parent, title: title, tags: tags, createdBy: createdBy, executor: try executor.executor(), createdAt: createdAt, lastActivityAt: lastActivityAt, hold: hold, work: work, errorMessage: errorMessage, lifecycle: lifecycle, group: group)
  }
}

struct QueueEntrySnapshot: Codable, Sendable {
  let id: Int
  let input: QueueInput
  init(_ entry: SessionQueueEntry) { id = entry.id; input = entry.input }
  var entry: SessionQueueEntry { .init(id: id, input: input) }
}

struct HydrationSnapshot: Codable, Sendable {
  let generation: Int
  let record: RecordSnapshot
  let transcriptKind: String
  let transcript: TranscriptSnapshot
  let undrained: [QueueEntrySnapshot]
  let queueHead: Int
  let queueTail: Int
  init(_ hydration: SessionHydration) {
    generation = hydration.generation; record = .init(hydration.record)
    switch hydration.transcript { case let .kernel(value): transcriptKind = "kernel"; transcript = .init(value) }
    undrained = hydration.undrained.map(QueueEntrySnapshot.init)
    queueHead = hydration.queueHead; queueTail = hydration.queueTail
  }

  func hydration() throws -> SessionHydration {
    guard transcriptKind == "kernel" else { throw WorkerProtocolError(.invalidMessage, message: "Unsupported transcript kind") }
    return try .init(generation: generation, record: record.record(), transcript: .kernel(transcript.value), undrained: undrained.map(\.entry), queueHead: queueHead, queueTail: queueTail)
  }
}

struct DrainSnapshot: Codable, Sendable {
  let items: [TranscriptItem]
  let queueTail: Int
  init(_ drain: QueueDrain) { items = drain.items; queueTail = drain.queueTail }
  var drain: QueueDrain { .init(items: items, queueTail: queueTail) }
}

struct RestartSnapshot: Codable, Sendable {
  let generation: Int
  let executor: ExecutorSnapshot
  init(_ restart: SessionRestart) { generation = restart.generation; executor = .init(restart.executor) }
  func restart() throws -> SessionRestart { .init(generation: generation, executor: try executor.executor()) }
}

struct CommandSnapshot: Codable, Sendable {
  let kind: String
  let instructions: String?
  init(_ command: SessionCommand) {
    switch command { case let .compact(value): kind = "compact"; instructions = value }
  }

  func command() throws -> SessionCommand {
    guard kind == "compact" else { throw WorkerProtocolError(.invalidMessage, message: "Unsupported session command") }
    return .compact(instructions: instructions)
  }
}

struct CompactClaimSnapshot: Codable, Sendable {
  let handle: String
  let transcript: TranscriptSnapshot
  func claim() throws -> CompactRequestClaim {
    guard !handle.isEmpty else { throw WorkerProtocolError(.invalidMessage, message: "Empty compact claim handle") }
    return .init(opaqueHandle: handle, transcript: transcript.value)
  }
}
