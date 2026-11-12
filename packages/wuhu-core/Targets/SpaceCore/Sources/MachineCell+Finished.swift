import enum MachineContract.ExecTimeout
import enum MachineContract.ExitStatus
import struct OperationProtocol.OperationError
import SessionDomain
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension MachineCell {
  func result(_ row: MachineOperation) -> ExecFinished {
    let termination = row.snapshot?.verdict?.result?.object?["termination"]?.object
    let status: ExitStatus? = if termination?["tag"]?.stringValue == "exit", let code = termination?["code"]?.intValue {
      .exited(code: code)
    } else if termination?["tag"]?.stringValue == "signal", let signal = termination?["signal"]?.intValue {
      .signaled(signal: signal)
    } else { nil }
    let error = row.diagnostic ?? row.snapshot?.verdict?.error ?? (status == nil ? OperationError(.operationEnded, message: row.snapshot?.verdict?.reason ?? "Machine exec ended without the process's status") : nil)
    return ExecFinished(id: row.id, status: status, error: error, tail: row.tail, cursor: row.cursor, cut: row.cut != nil, timedOut: row.stop == "timeout" ? (status == nil ? .statusUnknown : .killed) : nil)
  }

  mutating func finish(_ row: inout MachineOperation, error: OperationError) throws {
    if row.terminal { return }
    row.diagnostic = error; row.state = "retired"; row.flights = [:]; row.stopAt = nil; row.answerAt = nil
    try deliver(&row)
  }

  mutating func deliver(_ row: inout MachineOperation) throws {
    guard !row.delivered else { return }
    let end = result(row)
    if row.background, let session = row.request.session {
      let handle = "exec.\(row.id)"
      let ending = end.error.map { ": \($0.message)" } ?? end.status.map { ": \($0)" } ?? ""
      ctx.send(.put(SessionPut(.notification(.init(
        id: UUID.deterministic("exec-end", session.rawValue, row.request.toolCall?.rawValue ?? row.id),
        timestamp: Date(timeIntervalSince1970: Double(now) / 1000), kind: .exec,
        subscriptionID: .exec(row.id), content: .init(text: "\(handle) ended\(ending):\n" + String(decoding: end.tail, as: UTF8.self)),
      )))), to: Recipient<SessionMail>(kind: SessionMail.kind, key: session.rawValue))
    } else if let recipient = row.recipient {
      ctx.send(.finished(end), to: recipient)
    }
    let streams = ctx.sockets(of: ExecStream.self).filter { $0.opening.nonce == row.stream }
    for socket in streams {
      socket.send(.exit(end)); socket.close()
    }
    row.delivered = true; row.stopAt = nil; row.answerAt = nil
    if row.recipient == nil || row.background { row.tail = Data() }
    if streams.isEmpty {
      let buffers = buffers
      let operation = row.request.operation
      ctx.emit { buffers.discard(operation) }
    }
  }
}
