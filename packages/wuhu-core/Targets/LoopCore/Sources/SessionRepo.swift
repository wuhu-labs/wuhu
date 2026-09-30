import struct ClaudeStream.ClaudeCodeLog
import Foundation
import JSONValue
import OrderedCollections
import SessionDomain
import SpaceCore
import struct WuhuAI.AssistantMessage
import struct WuhuAI.AssistantMessageMetadata

struct SessionRepo: Sendable {
  var sessions: SessionStore
  var id: SessionID
  var queueHeadRead: @Sendable (SessionStore, SessionID) async throws -> Int = { try await $0.queueHead($1) }
  var pendingCommandRead: @Sendable (SessionStore, SessionID) async throws -> SessionCommand? = { try await $0.pendingCommand($1) }
  var archiveWrite: @Sendable (SessionStore, SessionID, Duration) async throws -> Date = { try await $0.archive($1, grace: $2) }

  func hydrate() async throws -> SessionHydration {
    try await sessions.hydrate(id)
  }

  func enqueue(input: QueueInput) async throws -> Int {
    try await sessions.enqueue(id, input: input)
  }

  func drainQueue() async throws -> QueueDrain {
    try await sessions.drainQueue(id)
  }

  func append(_ items: [TranscriptItem], transcript: Transcript) async throws {
    try await sessions.append(id, items: items, transcript: transcript)
  }

  func scopeContext(_ callID: ToolCallID) async throws -> ScopeContext? {
    try await sessions.scopeContext(id, toolCallID: callID)
  }

  func queueHead() async throws -> Int {
    try await queueHeadRead(sessions, id)
  }

  func pendingCommand() async throws -> SessionCommand? {
    try await pendingCommandRead(sessions, id)
  }

  func takeCommand() async throws -> SessionCommand? {
    try await sessions.takeCommand(id)
  }

  func writeCompaction(
    closing: ToolResultItem?,
    head: GenerationHead,
    kept: Range<Int>?,
  ) async throws -> Transcript {
    try await sessions.writeCompaction(id, closing: closing, head: head, kept: kept)
  }

  func markInterrupted() async throws {
    try await sessions.markInterrupted(id)
  }

  func markResumed() async throws {
    try await sessions.markResumed(id)
  }

  func markErrored(errorDescription: String) async throws {
    try await sessions.markErrored(id, message: errorDescription)
  }

  func archive(grace: Duration) async throws -> Date {
    try await archiveWrite(sessions, id, grace)
  }

  func unarchive() async throws {
    try await sessions.unarchive(id)
  }

  func restart(executor: SessionExecutor?, note: String?) async throws -> SessionRestart {
    try await sessions.restart(id, executor: executor, note: note)
  }

  func claudeCodeLog() async throws -> ClaudeCodeLog {
    try await sessions.claudeCodeLog(id)
  }

  func undrainedInputs() async throws -> [SessionQueueEntry] {
    try await sessions.undrainedInputs(id)
  }

  func claudeCodePendingNote() async throws -> String? {
    try await sessions.claudeCodePendingNote(id)
  }

  func beginClaudeCodeTurn() async throws {
    try await sessions.beginClaudeCodeTurn(id)
  }

  func appendClaudeCodeMirror(_ entries: [OrderedDictionary<String, JSONValue>], confirming handover: ClaudeCodeHandover?) async throws -> String? {
    try await sessions.appendClaudeCodeMirror(id, entries: entries, confirming: handover)
  }

  func claudeCodeOwedCompactionNotice() async throws -> CompactionTrigger? {
    try await sessions.claudeCodeOwedCompactionNotice(id)
  }

  func claudeCodeEnvironment(pendingSince: Date?) async throws -> SessionEnvironment {
    try await sessions.claudeCodeEnvironment(id, pendingSince: pendingSince)
  }

  func armedSubscriptions() async throws -> [ArmedSubscription] {
    try await sessions.armedSubscriptions(id)
  }

  func settleClaudeCodeTurn() async throws {
    try await sessions.settleClaudeCodeTurn(id)
  }
}
