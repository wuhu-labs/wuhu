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
import struct SpaceCore.SessionHome
import enum SpaceCore.SpaceError
import struct SpaceFS.SpacePath
import struct SpaceTools.MachineSeam
import Synchronization
import SystemFiles

extension InProcessToolOwnerClient {
  public func resolveImageDestination(_ raw: String, session: SessionID) async throws -> Address {
    try await resolve(raw, as: session)
  }

  public func refuseImageDestination(_ destination: Address, session: SessionID) async throws { try await refuseUnwritable(destination, by: session) }
  public func imageReceipt(_ session: SessionID, call: ToolCallID) async throws -> ToolResultPayload? { try await store.receipt(session, toolCallID: call) }
  public func placeImage(_ image: Data, at destination: Address, session: SessionID, call: ToolCallID?, state: ToolExecutionState?) async throws -> ToolResultPayload {
    let payload = try await MachineSeam.$caller.withValue(session) { try await place(image, at: destination, by: session, receipt: call) }
    if case .machine = destination, let call, let state {
      try await deliverContext(session, call, touching: destination.folder, state: state)
      try await store.recordReceipt(session, toolCallID: call, payload: payload)
    }
    return payload
  }

  private func refuseUnwritable(_ destination: Address, by session: SessionID) async throws {
    try refuseSystem(destination)
    if case let .space(path, group, _) = destination, let target = try? SpacePath(validating: path) {
      try await SessionHome.refuseForeignWrite(to: target, in: group, by: session, home: space.principal(of: session).group)
    }
    try await refuseExisting(destination)
  }

  private func place(
    _ image: Data,
    at destination: Address,
    by session: SessionID,
    receipt callID: ToolCallID?,
  ) async throws -> ToolResultPayload {
    switch destination {
    case let .space(path, group, _):
      do {
        return try await store.recordedSpaceWrite(
          session,
          toolCallID: callID,
          path: path,
          in: group,
          content: image,
          ifMatchRev: nil,
          payload: { .write(.init(path: destination.rendered, revision: .journal($0))) },
        ).payload
      } catch SpaceError.versionMismatch {
        throw neverOverwrites(destination.rendered)
      }
    case let .machine(machine, path):
      try await refuseExisting(destination)
      let revision = try await machineWrite(machine, path: path, bytes: [UInt8](image))
      return .write(.init(path: destination.rendered, revision: revision))
    case .system:
      throw systemReadOnly(destination)
    }
  }

  private func refuseExisting(_ destination: Address) async throws {
    let exists = switch destination {
    case let .space(path, group, _): (try? await space.fs(group).stat(path)) != nil
    case let .machine(machine, path): try await machineStat(machine, path: path) != nil
    case let .system(path): (try? await SystemFiles.vfs.stat(path)) != nil
    }
    if exists {
      throw neverOverwrites(destination.rendered)
    }
  }
}
