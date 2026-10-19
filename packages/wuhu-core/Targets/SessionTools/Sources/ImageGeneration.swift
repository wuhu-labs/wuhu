import enum MainHub.Address
import func MainHub.neverOverwrites
import struct MainHub.PNGHeader
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

  func claim(_ destination: Address) throws {
    guard case .machine = destination else { return }
    guard claimed.withLock({ $0.insert(destination).inserted }) else {
      throw neverOverwrites(destination.rendered)
    }
  }

  func release(_ destination: Address) {
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
    let destination = try await owner.resolveImageDestination(arguments.destination, session: session)
    if let recorded = try await owner.imageReceipt(session, call: callID) { return recorded }
    try await owner.refuseImageDestination(destination, session: session)
    let image = try await capabilities().image(arguments.prompt, options: .init(provider: arguments.provider, model: arguments.model, quality: arguments.quality, size: arguments.size))
    guard PNGHeader(image) != nil else { throw CapabilityError(.providerUnavailable, "The provider returned an image that is not a PNG.") }
    return try await owner.placeImage(image, at: destination, session: session, call: callID, state: state)
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
    let destination = try await owner.resolveImageDestination(raw, session: session)
    try claims.claim(destination)
    do {
      try await owner.refuseImageDestination(destination, session: session)
      guard images.count <= 5 else { throw CapabilityError(.invalidArgument, "At most five reference images are accepted.") }
      var input: [Data] = []
      for path in images {
        let bytes = try await owner.capabilityInput(path, as: session, limit: 25 * 1024 * 1024)
        guard PNGHeader(bytes) != nil else { throw CapabilityError(.invalidArgument, "Reference images must be PNG files.") }
        input.append(bytes)
      }
      let image = try await capabilities().image(prompt, images: input, options: options)
      guard let header = PNGHeader(image) else {
        throw CapabilityError(.providerUnavailable, "The provider returned an image that is not a PNG.")
      }
      _ = try await owner.placeImage(image, at: destination, session: session, call: nil, state: nil)
      return GeneratedImage(path: destination.rendered, bytes: image.count, width: header.width, height: header.height)
    } catch {
      claims.release(destination)
      throw error
    }
  }
}
