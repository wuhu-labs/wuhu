import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import StructuredQueries
import Wuwei
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension MachineCell {
  mutating func answerFile(_ frame: BoxSocket.Incoming, row: inout MachineFileOperation, purpose: BoxPurpose, presence: MachinePresence) throws {
    if try resetFileWorker(&row) { return }
    let operation = row.request.operation
    let abandonedOutput: Bool = switch purpose {
    case .output: row.delivered || row.stop != nil
    default: false
    }
    let abandonedInput: Bool = switch purpose {
    case .fileInput: row.delivered || row.stop != nil
    default: false
    }
    if abandonedOutput || abandonedInput {
      let buffers = buffers
      ctx.emit { buffers.discard(operation) }
      return
    }
    if row.failure != nil {
      if purpose == .stop {
        switch frame.answer {
        case .snapshot:
          try deleteFile(row)
        case let .box(error) where error.code == .unknownOperation,
             let .transport(error) where error.code == .unknownOperation:
          try deleteFile(row)
        case .transport:
          let retry = row.flights[purpose]?.retry ?? 100
          row.flights[purpose] = ExecFlight(due: now + retry, retry: min(2000, retry * 2), waiting: false)
          try saveFile(row)
        default: break
        }
      }
      return
    }
    let retry = row.flights[purpose]?.retry ?? 100
    row.flights[purpose] = nil
    var stalled = false
    switch frame.answer {
    case let .box(error), let .transport(error):
      if error.code == .unknownOperation || error.code == .offsetExpired {
        if row.delivered { try deleteFile(row) }
        else { try failFile(&row, lostFile(row)) }
        return
      } else if error.code == .operationEnded, case .fileInput = purpose {
        row.state = "reconciling"
      } else if purpose == .start, error.code == .operationExists {
        row.state = "running"
        readyFile(&row, piece: presence.piece)
      } else if [.transport, .requestDeadline, .requestCancelled, .machineUnavailable, .capacityExceeded].contains(error.code) {
        if purpose == .start { row.state = "reconciling" }
        else { stalled = true }
      } else { try failFile(&row, .operation(error)); return }
    case let .preparation(error):
      if purpose == .start { row.dispatched = false }
      try failFile(&row, .operation(error)); return
    case let .snapshot(answer):
      let snapshot = answer.snapshot
      guard snapshot.operation == operation, (snapshot.verdict == nil) == (snapshot.terminalToken == nil) else {
        try failFile(&row, .operation(.init(.invalidResponse))); return
      }
      guard (snapshot.verdict?.result?.jsonString().utf8.count ?? 0) <= presence.resultBytes! else {
        try failFile(&row, .operation(.init(.resultTooLarge))); return
      }
      if let known = row.snapshot?.verdict, let verdict = snapshot.verdict, known != verdict {
        try failFile(&row, .operation(.init(.invalidResponse))); return
      }
      var finals = row.snapshot?.finalOffsets ?? [:]
      for (channel, observed) in snapshot.finalOffsets {
        if let known = finals[channel], known != observed {
          try failFile(&row, .operation(.init(.invalidResponse))); return
        }
        finals[channel] = observed
      }
      if snapshot.channelEnd {
        guard let channel = snapshot.channel, purpose == .output(channel) || purpose == .terminal(channel),
              row.received[channel] != nil, let from = snapshot.from, let through = snapshot.through, through >= from,
              finals[channel].map({ $0 == through }) ?? true
        else { try failFile(&row, .operation(.init(.invalidResponse))); return }
        finals[channel] = through
      }
      guard row.received.allSatisfy({ channel, received in
        guard let final = finals[channel]?.rawValue else { return true }
        return row.endedChannels.contains(channel) ? received == final : received <= final
      }) else { try failFile(&row, .operation(.init(.invalidResponse))); return }
      switch purpose {
      case .start:
        row.state = "running"
        if row.stop == nil, !row.delivered { readyFile(&row, piece: presence.piece) }
      case .stop:
        try deleteFile(row)
        return
      case let .output(channel):
        guard snapshot.channel == channel, let from = snapshot.from, let through = snapshot.through, through >= from,
              let offset = row.offsets[channel], let received = row.received[channel]
        else {
          try failFile(&row, .operation(.init(.invalidResponse))); return
        }
        guard finals[channel].map({ through.rawValue <= $0.rawValue }) ?? true else {
          try failFile(&row, .operation(.init(.invalidResponse))); return
        }
        if from.rawValue == received, through > from {
          guard !row.endedChannels.contains(channel) else { try failFile(&row, .operation(.init(.invalidResponse))); return }
          guard let pointer = answer.output, pointer.worker == buffers.worker, pointer.operation == operation,
                pointer.channel == channel, pointer.from == from.rawValue, pointer.through == through.rawValue,
                buffers.payload(pointer) != nil
          else {
            try failFile(&row, .rangeLost(offset: offset)); return
          }
          row.received[channel] = through.rawValue
          if snapshot.channelEnd { row.endedChannels.insert(channel) }
          if row.offered[channel] == offset {
            row.offered[channel] = through.rawValue
            fileSocket(row)?.send(.output(pointer))
          }
        } else if from.rawValue > received {
          try failFile(&row, .rangeLost(offset: offset)); return
        } else if from.rawValue == received, through == from {
          if snapshot.channelEnd { row.endedChannels.insert(channel) }
          else { stalled = true }
        } else { stalled = true }
      case .control:
        if row.state == "reconciling" {
          row.state = "running"
          if row.stop == nil, !row.delivered { readyFile(&row, piece: presence.piece) }
        }
        stalled = snapshot.verdict == nil
      case let .terminal(channel):
        row.terminalAcks.insert(channel)
        stalled = true
      case .input, .fileInput: preconditionFailure("File input exchange answered with snapshot")
      }
      guard row.received.allSatisfy({ channel, received in
        guard let final = finals[channel]?.rawValue else { return true }
        return row.endedChannels.contains(channel) ? received == final : received <= final
      }) else { try failFile(&row, .operation(.init(.invalidResponse))); return }
      if case .terminal = purpose, snapshot.outputConsumed {
        let channels = row.offsets.isEmpty ? Set([""]) : Set(row.offsets.keys)
        if row.terminalAcks.isSuperset(of: channels) { try deleteFile(row); return }
      }
      let latest = row.snapshot?.verdict == nil || snapshot.verdict != nil ? snapshot : row.snapshot!
      row.snapshot = OperationSnapshot(
        operation: operation,
        verdict: latest.verdict,
        terminalToken: latest.terminalToken,
        finalOffsets: finals,
        outputConsumed: snapshot.outputConsumed,
        channel: latest.channel,
        from: latest.from,
        through: latest.through,
        channelEnd: latest.channelEnd,
        bufferReservationBytes: latest.bufferReservationBytes,
      )
      if row.snapshot?.verdict != nil { row.flights[.control] = nil }
    case let .input(receipt):
      guard case let .fileInput(channel) = purpose else { preconditionFailure("File input receipt answered a different exchange") }
      let accepted = row.inputOffsets[channel]!
      let through = receipt.acceptedThrough.rawValue
      if through < accepted || through == accepted && row.inputEnded.contains(channel) { return }
      guard let pending = buffers.pending(operation, accepted: row.inputOffsets, ended: row.inputEnded) else {
        if through == accepted, !receipt.end { return }
        try failFile(&row, .outcomeUnknown); return
      }
      if pending.0.channel != channel, through == accepted { return }
      guard pending.0.channel == channel, through >= accepted, through <= pending.0.through,
            !receipt.end || pending.1 && through == pending.0.through
      else { try failFile(&row, .operation(.init(.invalidResponse))); return }
      let progressed = through > accepted || receipt.end
      row.inputOffsets[channel] = through
      if receipt.end { row.inputEnded.insert(channel) }
      let complete = through == pending.0.through && (!pending.1 || receipt.end)
      if complete { fileSocket(row)?.send(.accepted(channel: channel, offset: through, end: receipt.end)) }
      stalled = !complete && (receipt.blocked || !progressed)
    case .description: preconditionFailure("File operation received describe")
    }
    if stalled {
      row.flights[purpose] = ExecFlight(due: now + retry, retry: min(2000, retry * 2), waiting: false)
    }
    try finishFileStep(&row, presence: presence)
  }
}
