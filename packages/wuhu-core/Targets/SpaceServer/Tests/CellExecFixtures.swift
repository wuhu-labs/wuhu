#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct MachineContract.ExecID
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.Verdict
@testable import SpaceCore
import Testing

func setExecTerminalFixture(space: Space, exec: ExecID, terminal: ExecTerminalState) async throws {
  let record = try #require(try await space.execRecord(exec))
  try await space.worker.call(MachineCell.ID(record.machine.rawValue)) { cell in
    var row = try #require(cell.operation(exec.rawValue))
    row.opened = terminal != .reaped
    row.state = "retired"
    row.delivered = true
    row.flights = [:]
    row.stopAt = nil
    row.answerAt = nil
    row.stop = terminal == .cancelled ? "callerCancelled" : nil
    let termination: JSONValue?
    switch terminal {
    case let .exited(code): termination = ["tag": "exit", "code": .number(Double(code))]
    case let .signaled(signal): termination = ["tag": "signal", "signal": .number(Double(signal))]
    case .cancelled, .machineLost, .reaped: termination = nil
    }
    row.snapshot = termination.map {
      OperationSnapshot(operation: row.request.operation, verdict: Verdict(.completed, result: ["termination": $0]), terminalToken: UUID(), finalOffsets: ["stdout": .zero, "stderr": .zero], outputConsumed: true)
    }
    try cell.save(row)
  }
  #expect(try await space.execRecord(exec)?.terminal == terminal)
}
