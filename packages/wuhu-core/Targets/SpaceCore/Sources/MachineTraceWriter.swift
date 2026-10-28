import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import Logging
import struct OperationProtocol.OperationTrace
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite
import Synchronization
import TaskLifetime

final class MachineTraceWriter: Sendable {
  private struct Entry: Sendable {
    let trace: OperationTrace
    let group: GroupID
    let problemsGroup: GroupID
    let stamp: String
  }

  private final class Buffer: Sendable {
    struct State {
      var entries: [Entry] = []
      var dropped = 0
      var closed = false
      var groups: [GroupID: GroupID] = [:]
    }

    let state = Mutex(State())
  }

  private let buffer = Buffer()
  private let scope = TaskScope()
  private let date: DateGenerator
  private let log: Logger

  init(writer: any DatabaseWriter, date: DateGenerator, clock: any Clock<Duration>, broadcast: FSBroadcast, log: Logger) {
    self.date = date; self.log = log
    try! scope.run("machine-trace-writer") { [buffer] in
      while !Task.isCancelled {
        var batchCount = 0
        do {
          try await clock.sleep(for: .milliseconds(100))
          let (entries, dropped) = buffer.state.withLock { state in
            let entries = Array(state.entries.prefix(128))
            state.entries.removeFirst(entries.count)
            let dropped = state.dropped; state.dropped = 0
            return (entries, dropped)
          }
          if dropped > 0 { log.warning("Machine traces dropped", metadata: ["count": "\(dropped)"]) }
          guard !entries.isEmpty else { continue }
          batchCount = entries.count
          try await writer.write { db in
            guard !buffer.state.withLock({ $0.closed }) else {
              log.warning("Machine traces dropped at shutdown", metadata: ["count": "\(entries.count)"])
              return
            }
            var pending: [MutationEvent] = []
            for entry in entries {
              let trace = entry.trace; let stamp = entry.stamp
              let parts = trace.elapsed.components
              let elapsed = Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
              let id = entry.group.rawValue + "/" + trace.request.uuidString
              let prior = try MachineV2TraceRow.where { $0.id.eq(id) }.fetchOne(db)
              var row = MachineV2TraceRow(id: id, grp: entry.group.rawValue, requestID: trace.request.uuidString, correlationID: trace.correlation, path: trace.path, event: trace.event.rawValue, startAt: prior?.startAt ?? stamp, elapsedMs: elapsed, status: trace.status ?? prior?.status, headMs: trace.event == .head ? elapsed : prior?.headMs, errorCode: trace.error?.rawValue, problemID: prior?.problemID)
              if let incident = try MachineV2IncidentRow.where({ $0.traceGroup.eq(entry.group.rawValue) && $0.correlationID.eq(trace.correlation) && $0.problemID.isNot(nil) }).fetchOne(db) { row.problemID = incident.problemID }
              try MachineV2TraceRow.upsert { row }.execute(db)
              if let code = trace.error, [.invalidResponse, .invalidOffset, .offsetExpired].contains(code) {
                let parts = trace.path.split(separator: "/").map(String.init)
                let operation = parts.count >= 6 ? UUID(uuidString: parts[5]) : nil
                _ = try V2Problems.record(group: entry.problemsGroup, traceGroup: entry.group, invariant: 13, code: code, incident: operation?.uuidString ?? trace.request.uuidString, correlation: UUID(uuidString: trace.correlation), stamp: stamp, in: db, pending: &pending)
              }
            }
            let events = pending
            if !events.isEmpty { db.afterNextTransaction(onCommit: { _ in
              broadcast.emit(Dictionary(grouping: events, by: \.rev).sorted { $0.key < $1.key }.map { rev, events in FSCommit(group: events[0].group, rev: rev, events: events) })
            }) }
          }
        } catch is CancellationError { break }
        catch { log.warning("Machine trace batch dropped", metadata: ["count": "\(batchCount)", "error": "\(error)"]) }
      }
    }
    try! scope.run("machine-trace-retention") { [buffer] in
      var cursors: [GroupID: (String, Int64)] = [:]
      while !Task.isCancelled {
        do {
          try await clock.sleep(for: .seconds(1))
          let now = date.now
          let cutoff = SQLiteDateFormat.string(from: now.addingTimeInterval(-7 * 86400))
          let groups = buffer.state.withLock { $0.groups }
          let previous = cursors
          cursors = try await writer.write { db in
            guard !buffer.state.withLock({ $0.closed }) else { return previous }
            var next = previous
            for (traceGroup, group) in groups {
              if try V2Maintenance.due("problems/" + group.rawValue, now: now, in: db) {
                try V2Problems.releaseResolvedPins(group: group, stamp: SQLiteDateFormat.string(from: now), cutoff: cutoff, in: db)
              }
              next[traceGroup] = try Self.prune(group: traceGroup, cutoff: cutoff, after: previous[traceGroup], in: db)
            }
            return next
          }
        } catch is CancellationError { break }
        catch { log.warning("Machine trace retention failed", metadata: ["error": "\(error)"]) }
      }
    }
  }

  deinit { scope.cancel() }

  func append(_ trace: OperationTrace, group: GroupID, problemsGroup: GroupID) {
    let stamp = SQLiteDateFormat.string(from: date.now)
    buffer.state.withLock { state in
      guard !state.closed else { return }
      state.groups[group] = problemsGroup
      guard state.entries.count < 1024 else { state.dropped += 1; return }
      state.entries.append(Entry(trace: trace, group: group, problemsGroup: problemsGroup, stamp: stamp))
    }
  }

  func problemsGroup(for group: GroupID) -> GroupID? { buffer.state.withLock { $0.groups[group] } }

  func close() async {
    let dropped = buffer.state.withLock { state in
      state.closed = true
      let dropped = state.entries.count + state.dropped
      state.entries.removeAll(); state.dropped = 0
      return dropped
    }
    if dropped > 0 { log.warning("Machine traces dropped at shutdown", metadata: ["count": "\(dropped)"]) }
    await scope.close()
  }

  static func prune(group: GroupID, cutoff: String, after cursor: (String, Int64)?, in db: Database) throws -> (String, Int64)? {
    let rows = try Row.fetchAll(db, sql: """
    SELECT rowid, id, start_at, problem_id FROM machine_v2_trace
    WHERE grp = ? AND start_at < ? AND (start_at, rowid) > (?, ?)
    ORDER BY start_at, rowid LIMIT 512
    """, arguments: [group.rawValue, cutoff, cursor?.0 ?? "", cursor?.1 ?? 0])
    let ids: [String] = rows.compactMap { row in
      let problem: Int64? = row["problem_id"]
      return problem == nil ? row["id"] : nil
    }
    if !ids.isEmpty { try MachineV2TraceRow.where { $0.id.in(ids) }.delete().execute(db) }
    guard rows.count == 512, let last = rows.last else { return nil }
    return (last["start_at"], last["rowid"])
  }
}
