#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import enum Credentials.ProviderCredential
import Dependencies
import Fetch
import struct InferenceKit.CapabilityError
import struct InferenceKit.CapabilityOptions
import SessionDomain
import struct SpaceContract.GroupID
import struct SpaceCore.SessionHome
import enum SpaceCore.SpaceError
import struct SpaceFS.SpacePath
import struct SpaceTools.MachineSeam
import Synchronization
import SystemFiles

extension Hub {
  nonisolated public func resolveImageDestination(_ raw: String, session: SessionID) async throws -> Address {
    try await resolve(raw, as: session)
  }

  nonisolated public func refuseImageDestination(_ destination: Address, session: SessionID) async throws { try await refuseUnwritable(destination, by: session) }
  nonisolated public func imageReceipt(_ session: SessionID, call: ToolCallID) async throws -> ToolResultPayload? { try await store.receipt(session, toolCallID: call) }
  nonisolated public func placeImage(_ image: Data, at destination: Address, session: SessionID, call: ToolCallID?) async throws -> ToolResultPayload {
    let payload = try await MachineSeam.$caller.withValue(session) { try await place(image, at: destination, by: session, receipt: call) }
    if case .machine = destination, let call {
      try await store.recordReceipt(session, toolCallID: call, payload: payload)
    }
    return payload
  }

  nonisolated private func refuseUnwritable(_ destination: Address, by session: SessionID) async throws {
    try Addressing.refuseSystem(destination)
    let home = try await space.principal(of: session).group
    if case let .space(path, group) = destination, let target = try? SpacePath(validating: path) {
      try SessionHome.refuseForeignWrite(to: target, in: group ?? home, by: session, home: home)
    }
    try await refuseExisting(destination, acting: home)
  }

  nonisolated private func place(
    _ image: Data,
    at destination: Address,
    by session: SessionID,
    receipt callID: ToolCallID?,
  ) async throws -> ToolResultPayload {
    switch destination {
    case let .space(path, group):
      let acting = try await space.principal(of: session).group
      do {
        return try await store.recordedSpaceWrite(
          session,
          toolCallID: callID,
          path: path,
          in: group ?? acting,
          content: image,
          ifMatchRev: nil,
          payload: { .write(.init(path: destination.rendered, revision: .journal($0))) },
        ).payload
      } catch SpaceError.versionMismatch {
        throw neverOverwrites(destination.rendered)
      }
    case let .machine(machine, path):
      try await refuseExisting(destination, acting: nil)
      let revision = try await machineWrite(machine, path: path, bytes: [UInt8](image))
      return .write(.init(path: destination.rendered, revision: revision))
    case .system:
      throw Addressing.systemReadOnly(destination)
    }
  }

  nonisolated private func refuseExisting(_ destination: Address, acting: GroupID?) async throws {
    let exists = switch destination {
    case let .space(path, group): (try? await space.fs(group ?? acting ?? .shared).stat(path)) != nil
    case let .machine(machine, path): try await machineStat(machine, path: path) != nil
    case let .system(path): (try? await SystemFiles.vfs.stat(path)) != nil
    }
    if exists {
      throw neverOverwrites(destination.rendered)
    }
  }
}
