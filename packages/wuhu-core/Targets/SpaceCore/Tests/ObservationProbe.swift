import enum SpaceCore.ObservationReply
import struct SpaceCore.ObservationSlot
import struct SpaceCore.Rows
import Wuwei

struct ObservationProbeOutput: Sendable {
  let send: @Sendable (ObservationReply) -> Void
}

@Cell
struct ObservationProbe {
  mutating func observed(_ slot: ObservationSlot, _ rows: Rows, _ marker: String) {
    let output = ctx.dependency(ObservationProbeOutput.self)
    ctx.emit { output.send(.observed(slot, rows, marker)) }
  }

  mutating func failed(_ slot: ObservationSlot, _ reason: String) {
    let output = ctx.dependency(ObservationProbeOutput.self)
    ctx.emit { output.send(.failed(slot, reason)) }
  }
}
