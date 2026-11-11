import SessionDomain
import struct SpaceCore.GroupCell
import struct SpaceCore.Principal
import struct SpaceCore.SessionRecord
import struct SpaceCore.StoredTranscriptLine
import struct SpaceCore.TranscriptCursor
import Wuwei

/// A session's live transcript lines. On attach: `reset` with every line of the current generation, or, when `after` is in the current generation, the lines past it and its prompt lines again, which are written late into the first positions. Then each line as it is written, and a `reset` for each new generation. A client places lines by position. The cell closes the socket instead of sending to a viewer who no longer reads the session's group.
public enum TranscriptTail: Socket {
  public struct Opening: Sendable {
    var after: TranscriptCursor?
    var viewer: Principal
  }

  public enum Outgoing: Sendable {
    case reset(generation: Int, lines: [StoredTranscriptLine])
    case lines(generation: Int, [StoredTranscriptLine])
  }
}

extension SessionCell {
  func catchUp(_ socket: SocketHandle<TranscriptTail>) throws {
    guard let record = try? rows.record(id.session), reads(record, socket.opening.viewer) else { return socket.close() }
    let end = try rows.lineEnd(id.session)
    guard let after = socket.opening.after, after.generation == end.generation else {
      return socket.send(.reset(generation: end.generation, lines: try rows.lines(id.session, generation: end.generation, after: -1)))
    }
    let lines = try rows.lines(id.session, generation: end.generation, after: after.position, prompt: true)
    if !lines.isEmpty { socket.send(.lines(generation: end.generation, lines)) }
  }

  /// Every step ends by sending the lines it wrote, whichever handler wrote them.
  mutating func around(_ call: (inout Self) throws -> Void) throws {
    guard !ctx.sockets(of: TranscriptTail.self).isEmpty else { return try call(&self) }
    let mark = try rows.lineEnd(id.session)
    try call(&self)
    let end = try rows.lineEnd(id.session)
    if end.generation != mark.generation {
      try publish(.reset(generation: end.generation, lines: rows.lines(id.session, generation: end.generation, after: -1)))
    } else if end.position > mark.position {
      try publish(.lines(generation: end.generation, rows.lines(id.session, generation: end.generation, after: mark.position)))
    }
  }

  /// Main stores the prompt into the first positions during an inference, outside the cell's calls: each step's outcome until the generation's first reply sends the prompt lines again.
  func sendPrompt() throws {
    guard !ctx.sockets(of: TranscriptTail.self).isEmpty else { return }
    let end = try rows.lineEnd(id.session)
    let lines = try rows.lines(id.session, generation: end.generation, after: .max, prompt: true)
    if !lines.isEmpty { try publish(.lines(generation: end.generation, lines)) }
  }

  private func publish(_ frame: TranscriptTail.Outgoing) throws {
    let record = try rows.record(id.session)
    for socket in ctx.sockets(of: TranscriptTail.self) {
      if reads(record, socket.opening.viewer) { socket.send(frame) } else { socket.close() }
    }
  }

  private func reads(_ record: SessionRecord, _ viewer: Principal) -> Bool {
    ctx.cell(GroupCell.ID(record.group.rawValue)).reads(viewer)
  }
}
