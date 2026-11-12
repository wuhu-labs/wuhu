import struct OperationProtocol.ChannelPayload
import Synchronization
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct MachinePointer: Hashable, Sendable {
  public var worker: String
  public var operation: UUID
  public var channel: String
  public var from: UInt64
  public var through: UInt64
  public init(worker: String, operation: UUID, channel: String, from: UInt64, through: UInt64) {
    self.worker = worker; self.operation = operation; self.channel = channel; self.from = from; self.through = through
  }
}

public final class MachineBuffers: Sendable {
  private struct Piece {
    var payload: ChannelPayload
    var count = 1
  }

  private struct Window {
    var pieces: [MachinePointer: Piece] = [:]
    var cursors: [MachinePointer: Int] = [:]
    var inputs: [(MachinePointer, Bool)] = []
    var floors: [String: UInt64] = [:]
    var released: [String: UInt64] = [:]
  }

  public let worker: String
  private let windows = Mutex<[UUID: Window]>([:])
  public init(worker: String) { self.worker = worker }

  var operationCount: Int { windows.withLock { $0.count } }

  public func put(_ bytes: Data, operation: UUID, channel: String, from: UInt64) -> MachinePointer? {
    put(payload: ChannelPayload(data: bytes), operation: operation, channel: channel, from: from)
  }

  public func put(payload: ChannelPayload, operation: UUID, channel: String, from: UInt64) -> MachinePointer? {
    let pointer = MachinePointer(worker: worker, operation: operation, channel: channel, from: from, through: from + UInt64(payload.count))
    return windows.withLock { windows in
      if payload.count > 0, pointer.through <= windows[operation]?.floors[channel] ?? 0 { return pointer }
      var stored = pointer
      var suffix = payload
      if let floor = windows[operation]?.released[channel], pointer.from < floor {
        if pointer.through <= floor { return pointer }
        stored.from = floor
        suffix = payload.slice(Int(floor - pointer.from) ..< payload.count)
      }
      if var old = windows[operation]?.pieces[stored] {
        precondition(old.payload == suffix)
        old.count += 1
        windows[operation]?.pieces[stored] = old
        return pointer
      }
      let retained = windows[operation]?.pieces.filter { $0.key.channel == channel }.values.reduce(0) { $0 + $1.payload.byteCount } ?? 0
      guard retained + suffix.byteCount <= 4 << 20 else { return nil }
      windows[operation, default: Window()].pieces[stored] = Piece(payload: suffix)
      return pointer
    }
  }

  public func read(_ pointer: MachinePointer) -> Data? {
    guard pointer.worker == worker else { return nil }
    return windows.withLock { $0[pointer.operation]?.pieces[pointer]?.payload.data }
  }

  public func payload(_ pointer: MachinePointer) -> ChannelPayload? {
    guard pointer.worker == worker, pointer.from <= pointer.through else { return nil }
    return windows.withLock { windows in
      guard let window = windows[pointer.operation] else { return nil }
      if let piece = window.pieces[pointer] { return piece.payload }
      guard let (pointerRange, piece) = window.pieces.first(where: {
        $0.key.channel == pointer.channel && $0.key.from <= pointer.from && $0.key.through >= pointer.through
      }) else { return nil }
      return piece.payload.slice(Int(pointer.from - pointerRange.from) ..< Int(pointer.through - pointerRange.from))
    }
  }

  public func get(_ operation: UUID, channel: String, from: UInt64) -> MachinePointer? {
    windows.withLock { windows in
      guard let piece = windows[operation]?.pieces.keys.filter({
        $0.channel == channel && $0.from <= from && from < $0.through
      }).max(by: { $0.through < $1.through }) else { return nil }
      return MachinePointer(worker: worker, operation: operation, channel: channel, from: from, through: piece.through)
    }
  }

  public func retained(_ operation: UUID, channel: String) -> Int {
    windows.withLock { windows in
      windows[operation]?.pieces.filter { $0.key.channel == channel }.values.reduce(0) { $0 + $1.payload.byteCount } ?? 0
    }
  }

  public func retained(_ operation: UUID, channel: String, from: UInt64) -> Int {
    windows.withLock { windows in
      windows[operation]?.pieces.reduce(0) { total, entry in
        let (pointer, piece) = entry
        guard pointer.channel == channel, pointer.through > from else { return total }
        if pointer.from >= from { return total + piece.payload.byteCount }
        return total + piece.payload.slice(Int(from - pointer.from) ..< piece.payload.count).byteCount
      } ?? 0
    }
  }

  public func release(_ pointer: MachinePointer) {
    guard pointer.worker == worker else { return }
    windows.withLock { windows in
      guard var window = windows[pointer.operation] else { return }
      var stored = pointer
      stored.from = max(stored.from, window.released[stored.channel] ?? stored.from)
      if var piece = window.pieces[stored] {
        piece.count -= 1
        window.pieces[stored] = piece.count == 0 ? nil : piece
      }
      if window.pieces.isEmpty, window.cursors.isEmpty, window.inputs.isEmpty, window.floors.isEmpty, window.released.isEmpty {
        windows[pointer.operation] = nil
      } else { windows[pointer.operation] = window }
    }
  }

  public func release(_ operation: UUID, channel: String, before: UInt64) {
    windows.withLock { windows in
      guard var window = windows[operation] else { return }
      for (pointer, piece) in window.pieces where pointer.channel == channel && pointer.from < before {
        window.pieces[pointer] = nil
        window.cursors[pointer] = nil
        if pointer.through > before {
          let rest = MachinePointer(worker: worker, operation: operation, channel: channel, from: before, through: pointer.through)
          window.pieces[rest] = Piece(payload: piece.payload.slice(Int(before - pointer.from) ..< piece.payload.count), count: piece.count)
        }
      }
      window.released[channel] = max(window.released[channel, default: 0], before)
      windows[operation] = window
    }
  }

  func retained(_ operation: UUID, channel: String, consumed: Int) -> Int {
    windows.withLock { windows in
      guard let window = windows[operation] else { return 0 }
      return window.pieces.filter { $0.key.channel == channel && window.cursors[$0.key].map { $0 > consumed } != false }.values.reduce(0) { $0 + $1.payload.byteCount }
    }
  }

  func prefix(_ pointer: MachinePointer, count: Int) -> MachinePointer {
    precondition(count > 0 && UInt64(count) <= pointer.through - pointer.from)
    let bytes = read(pointer)!
    let limited = MachinePointer(worker: worker, operation: pointer.operation, channel: pointer.channel, from: pointer.from, through: pointer.from + UInt64(count))
    windows.withLock { $0[pointer.operation]?.pieces[limited] = Piece(payload: ChannelPayload(data: Data(bytes.prefix(count)))) }
    return limited
  }

  func delivered(_ pointer: MachinePointer, cursor: Int) {
    windows.withLock { $0[pointer.operation]?.cursors[pointer] = cursor }
  }

  func consumed(_ operation: UUID, cursor: Int) {
    windows.withLock { windows in
      guard var window = windows[operation] else { return }
      for (pointer, end) in window.cursors where end <= cursor {
        window.pieces[pointer] = nil; window.cursors[pointer] = nil
        window.floors[pointer.channel] = max(window.floors[pointer.channel, default: 0], pointer.through)
      }
      windows[operation] = window
    }
  }

  func remove(_ pointer: MachinePointer) {
    windows.withLock { windows in
      windows[pointer.operation]?.pieces[pointer] = nil
      let floor = max(windows[pointer.operation]?.floors[pointer.channel] ?? 0, pointer.through)
      windows[pointer.operation]?.floors[pointer.channel] = floor
    }
  }

  func pend(_ pointer: MachinePointer, end: Bool, accepted: UInt64, window: Int) -> Bool {
    guard pointer.worker == worker, pointer.through >= pointer.from, let payload = payload(pointer), payload.byteCount <= 65536 else { return false }
    return windows.withLock { windows in
      var state = windows[pointer.operation] ?? Window()
      guard state.pieces[pointer] != nil else { return false }
      if state.inputs.contains(where: { $0.0 == pointer && $0.1 == end }) { return true }
      let inputs = state.inputs.filter { $0.0.channel == pointer.channel && ($0.0.through > accepted || $0.1) }
      let queued = inputs.last?.0.through ?? accepted
      if !end, pointer.through <= queued { return true }
      let room: Bool
      if payload.data != nil { room = pointer.through >= accepted && pointer.through - accepted <= UInt64(window) }
      else {
        let retained = inputs.reduce(0) { total, input in
          let piece = state.pieces[input.0]!.payload
          let consumed = min(piece.count, Int(max(input.0.from, accepted) - input.0.from))
          return total + piece.slice(consumed ..< piece.count).byteCount
        }
        room = retained + payload.byteCount <= window
      }
      guard inputs.last?.1 != true, end ? pointer.from == queued : max(pointer.from, accepted) <= queued, room else { return false }
      state.inputs.append((pointer, end)); windows[pointer.operation] = state
      return true
    }
  }

  func pending(_ operation: UUID) -> (MachinePointer, Bool)? {
    windows.withLock { $0[operation]?.inputs.first }
  }

  func pending(_ operation: UUID, accepted: [String: UInt64], ended: Set<String>) -> (MachinePointer, Bool)? {
    windows.withLock {
      $0[operation]?.inputs.first { pointer, end in
        pointer.through > accepted[pointer.channel, default: 0] || end && !ended.contains(pointer.channel)
      }
    }
  }

  func input(_ operation: UUID, channel: String = "stdin", accepted: UInt64) -> (MachinePointer, Bool)? {
    windows.withLock { windows in
      guard let (pointer, end) = windows[operation]?.inputs.first(where: { $0.0.channel == channel && ($0.0.through > accepted || $0.1) }) else { return nil }
      if pointer.from >= accepted { return (pointer, end) }
      let rest = MachinePointer(worker: worker, operation: operation, channel: channel, from: accepted, through: pointer.through)
      let bytes = windows[operation]!.pieces[pointer]!.payload
      windows[operation]?.pieces[rest] = Piece(payload: bytes.slice(Int(accepted - pointer.from) ..< bytes.count))
      return (rest, end)
    }
  }

  public func accepted(_ operation: UUID, channel: String = "stdin", through: UInt64, ended: Bool) {
    windows.withLock { windows in
      defer {
        let pending = Set((windows[operation]?.inputs ?? []).map(\.0))
        for pointer in windows[operation]?.pieces.keys.filter({ $0.channel == channel && $0.through <= through && !pending.contains($0) }) ?? [] {
          windows[operation]?.pieces[pointer] = nil
        }
      }
      while let index = windows[operation]?.inputs.firstIndex(where: { $0.0.channel == channel }) {
        let (pointer, end) = windows[operation]!.inputs[index]
        guard through >= pointer.from else { return }
        if through >= pointer.through && (!end || ended) {
          windows[operation]?.inputs.remove(at: index)
          windows[operation]?.pieces[pointer] = nil
          continue
        }
        if through > pointer.from {
          let bytes = windows[operation]!.pieces.removeValue(forKey: pointer)!.payload
          let rest = MachinePointer(worker: worker, operation: operation, channel: channel, from: through, through: pointer.through)
          windows[operation]?.pieces[rest] = Piece(payload: bytes.slice(Int(through - pointer.from) ..< bytes.count))
          windows[operation]?.inputs[index] = (rest, end)
        }
        return
      }
    }
  }

  func endInput(_ operation: UUID) {
    windows.withLock { windows in
      for (pointer, _) in windows[operation]?.inputs ?? [] { windows[operation]?.pieces[pointer] = nil }
      windows[operation]?.inputs = []
    }
  }

  public func discard(_ operation: UUID) { _ = windows.withLock { $0.removeValue(forKey: operation) } }
}
