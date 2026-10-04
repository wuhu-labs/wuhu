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
import Synchronization
import SystemFiles

struct GeneratedImage: Equatable {
  let path: String
  let bytes: Int
  let width: Int
  let height: Int
}

// A machine write is stat-then-write, so two calls of one script run racing to
// the same machine path would both pass the stat. A space write needs no claim:
// its commit is create-only.
final class MachineWriteClaims: Sendable {
  private let claimed = Mutex<Set<Address>>([])

  fileprivate func claim(_ destination: Address) throws {
    guard case .machine = destination else { return }
    guard claimed.withLock({ $0.insert(destination).inserted }) else {
      throw neverOverwrites(destination.rendered)
    }
  }

  fileprivate func release(_ destination: Address) {
    _ = claimed.withLock { $0.remove(destination) }
  }
}

extension ToolExecutor {
  func generateImage(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: GenerateImageArguments,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    let destination = try await resolve(arguments.destination, as: session)
    if let recorded = try await store.receipt(session, toolCallID: callID) { return recorded }
    try await refuseUnwritable(destination, by: session)
    let image = try await capabilities().image(arguments.prompt, options: .init(provider: arguments.provider, model: arguments.model, quality: arguments.quality, size: arguments.size))
    guard PNGHeader(image) != nil else { throw CapabilityError(.providerUnavailable, "The provider returned an image that is not a PNG.") }
    let payload = try await place(image, at: destination, by: session, receipt: callID)
    if case .machine = destination {
      try await deliverContext(session, callID, touching: destination.folder, state: state)
      try await store.recordReceipt(session, toolCallID: callID, payload: payload)
    }
    return payload
  }

  // The run_script side of generate_image: the same checks, provider and
  // write, with no receipt and no context delivery.
  func generateImage(
    _ session: SessionID,
    prompt: String,
    destination raw: String,
    claims: MachineWriteClaims,
    images: [String] = [],
    options: CapabilityOptions = .init(),
  ) async throws -> GeneratedImage {
    let destination = try await resolve(raw, as: session)
    try claims.claim(destination)
    do {
      try await refuseUnwritable(destination, by: session)
      guard images.count <= 5 else { throw CapabilityError(.invalidArgument, "At most five reference images are accepted.") }
      var input: [Data] = []
      for path in images {
        let bytes = try await capabilityInput(path, as: session, limit: 25 * 1024 * 1024)
        guard PNGHeader(bytes) != nil else { throw CapabilityError(.invalidArgument, "Reference images must be PNG files.") }
        input.append(bytes)
      }
      let image = try await capabilities().image(prompt, images: input, options: options)
      guard let header = PNGHeader(image) else {
        throw CapabilityError(.providerUnavailable, "The provider returned an image that is not a PNG.")
      }
      _ = try await place(image, at: destination, by: session, receipt: nil)
      return GeneratedImage(path: destination.rendered, bytes: image.count, width: header.width, height: header.height)
    } catch {
      claims.release(destination)
      throw error
    }
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

private func neverOverwrites(_ path: String) -> ToolProblem {
  ToolProblem("\(path) already exists; generate_image never overwrites")
}

struct PNGHeader: Equatable {
  let width: Int
  let height: Int

  init?(_ data: Data) {
    let bytes = [UInt8](data.prefix(24))
    guard bytes.count == 24,
          bytes[0 ..< 8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
          bytes[12 ..< 16].elementsEqual(Array("IHDR".utf8))
    else { return nil }
    func word(_ at: Int) -> Int { bytes[at ..< at + 4].reduce(0) { $0 << 8 | Int($1) } }
    width = word(16)
    height = word(20)
  }
}
