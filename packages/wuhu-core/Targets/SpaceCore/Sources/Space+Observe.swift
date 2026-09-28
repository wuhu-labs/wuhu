import Foundation
import GRDB
import JSONValue
import Logging
import struct SpaceContract.GroupID
import SpaceSQL

extension Space {
  public func observeFS(glob: String, from: Rev? = nil, group: GroupID) -> AsyncStream<MutationEvent> {
    // Live subscription is registered before the journal snapshot is read, so
    // every committed rev lands in at least one of the two; the live copy of a
    // replayed rev (from < rev <= ceiling, and nothing else) is dropped.
    let live = broadcast.subscribe(glob: glob, group: group)
    guard let from else { return live }
    let writer = writer
    return AsyncStream { continuation in
      let task = Task {
        let ceiling: Int
        do {
          let journal = try await Self.journalEvents(after: from.value, group: group, writer: writer)
          ceiling = journal.ceiling
          for event in journal.events where FSBroadcast.matches(glob, event) {
            continuation.yield(event)
          }
        } catch {
          continuation.finish()
          return
        }
        for await event in live where event.rev <= from.value || event.rev > ceiling {
          continuation.yield(event)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func journalEvents(
    after from: Int,
    group: GroupID,
    writer: any DatabaseWriter,
  ) async throws -> (ceiling: Int, events: [MutationEvent]) {
    try await writer.read { db in
      let ceiling = Int(try Substrate.maxRevision(in: db))
      struct JournalRow {
        let path: String
        let rev: Int
        let kind: String?
        let op: JournalOp
        let aux: String?
      }
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT path, rev, kind, op, aux FROM fs_versions WHERE grp = ? AND rev > ? ORDER BY rev, path",
        arguments: [group.rawValue, from],
      ).map { row in
        JournalRow(
          path: row["path"], rev: Int(row["rev"] as Int64), kind: row["kind"],
          op: JournalOp(rawValue: row["op"])!, aux: row["aux"],
        )
      }
      var events: [MutationEvent] = []
      var index = rows.startIndex
      while index < rows.endIndex {
        let rev = rows[index].rev
        let batch = rows[index...].prefix { $0.rev == rev }
        index += batch.count
        // A move journals two rows per node: a tombstone at the source and a
        // write at the destination. The move event carries both ends, so the
        // destination write row is suppressed.
        let moveDestinations = Set(batch.compactMap { $0.op == .move ? $0.aux : nil })
        let kinds = batch.reduce(into: [String: String]()) { acc, row in
          if let kind = row.kind { acc[row.path] = kind }
        }
        for row in batch {
          switch row.op {
          case .move:
            events.append(MutationEvent(
              group: group, path: row.aux!, from: row.path, rev: rev, kind: .move,
              entry: Substrate.entryKind(kinds[row.aux!]!),
            ))
          case .write, .delete, .checkout:
            if let kind = row.kind {
              if !moveDestinations.contains(row.path) {
                events.append(MutationEvent(group: group, path: row.path, rev: rev, kind: .write, entry: Substrate.entryKind(kind)))
              }
            } else {
              events.append(MutationEvent(group: group, path: row.path, rev: rev, kind: .delete, entry: nil))
            }
          }
        }
      }
      return (ceiling, events)
    }
  }

  // A snapshot the reader never saw is not news: a consumer slower than the
  // writes resumes on the current state, not on the backlog it missed.
  public func observeQuery(
    _ sql: String,
    parameters: [JSONValue] = [],
    throttle: Duration,
    viewer: String? = nil,
    as principal: Principal,
  ) -> AsyncThrowingStream<Rows, any Error> {
    let writer = writer
    let reads = reads
    let clock = clock
    let resolve: @Sendable () async throws -> ReadScope = {
      let readable = try await writer.read { db in try Groups.reads(principal.group, in: db) }
      return ReadScope(acting: principal.group, readable: readable, viewer: viewer, member: principal.member)
    }
    return AsyncThrowingStream<Rows, any Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        let arguments: [DatabaseValue]
        do {
          arguments = try Self.bound(parameters)
        } catch {
          continuation.finish(throwing: error)
          return
        }
        await Self.runQueryObservation(
          sql: sql, arguments: arguments, throttle: throttle, resolve: resolve, writer: writer, reads: reads, clock: clock,
          continuation: continuation,
        )
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // The region is the space tables the statement reads, whole, and the read
  // graph: a write to a row no view shows wakes the observation, and the
  // unchanged snapshot is not yielded. Each wake re-resolves the scope, so a
  // removed read edge ends the observation with the refusal a new query meets.
  private static func runQueryObservation(
    sql: String,
    arguments: [DatabaseValue],
    throttle: Duration,
    resolve: @Sendable () async throws -> ReadScope,
    writer: any DatabaseWriter,
    reads: ReadPool,
    clock: any Clock<Duration>,
    continuation: AsyncThrowingStream<Rows, any Error>.Continuation,
  ) async {
    func region(_ tables: ReadTables) -> AsyncStream<Void> {
      regionWakes(tables.names.union(["group_reads"]).sorted().map { Table($0) }, in: writer)
    }
    var scope: ReadScope
    var tables: ReadTables
    var wakes: AsyncStream<Void>.Iterator
    var last: Rows
    do {
      scope = try await resolve()
      tables = try await Self.tables(sql, scope: scope, in: reads)
      wakes = region(tables).makeAsyncIterator()
      last = try await Self.read(sql, arguments: arguments, scope: scope, in: reads)
      continuation.yield(last)
    } catch {
      continuation.finish(throwing: error)
      return
    }

    while await wakes.next() != nil {
      if Task.isCancelled { break }
      if throttle != .zero { try? await clock.sleep(for: throttle) }
      if Task.isCancelled { break }
      let rows: Rows
      do {
        let current = try await resolve()
        if current != scope {
          scope = current
          let read = try await Self.tables(sql, scope: scope, in: reads)
          if read != tables {
            tables = read
            wakes = region(tables).makeAsyncIterator()
          }
        }
        rows = try await Self.read(sql, arguments: arguments, scope: scope, in: reads)
      } catch {
        continuation.finish(throwing: error)
        return
      }
      if rows != last {
        last = rows
        continuation.yield(rows)
      }
    }
    continuation.finish()
  }
}
