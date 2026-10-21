#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct InferenceKit.CapabilityError
import struct InferenceKit.CapabilityOptions
import JSONValue
import enum MainHub.Address
import enum MainHub.Addressing
import struct MainHub.ToolProblem
import SessionDomain
import SpaceClient
import struct SpaceContract.WriteOutput
import struct SpaceCore.SessionHome
import enum SpaceCore.SpaceError
import struct SpaceFS.SpacePath
import Synchronization

struct GeneratedImage: Equatable {
  let path: String
  let bytes: Int
  let width: Int
  let height: Int
}

func neverOverwrites(_ path: String) -> ToolProblem {
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
  // The agent's generate_image. Main's recorded answer for the call stands in
  // for a repeat, so a replay never pays for a second generation; otherwise
  // the destination is checked, the image generated and placed create-only.
  func generateImage(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: GenerateImageArguments,
  ) async throws -> ToolResultPayload {
    let destination = try await resolvedAddress(arguments.destination, as: session)
    try Addressing.refuseSystem(destination)
    let recorded = try await client(session, toolCall: callID.rawValue)
    if let answer = try await receipt(recorded, for: destination) {
      return .write(.init(path: destination.rendered, revision: try revision(answer.token, at: destination)))
    }
    try await refuseForeignHome(destination, session)
    try await refuseExisting(destination, session)
    let options = CapabilityOptions(provider: arguments.provider, model: arguments.model, quality: arguments.quality, size: arguments.size)
    let image = try await image(session, arguments.prompt, images: [], options: options)
    return try await place(image, at: destination, recorded)
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
    let destination = try await resolvedAddress(raw, as: session)
    try Addressing.refuseSystem(destination)
    try claims.claim(destination)
    do {
      try await refuseForeignHome(destination, session)
      try await refuseExisting(destination, session)
      guard images.count <= 5 else { throw CapabilityError(.invalidArgument, "At most five reference images are accepted.") }
      var input: [Data] = []
      for path in images {
        let bytes = try await capabilityInput(session, path, limit: 25 * 1024 * 1024)
        guard PNGHeader(bytes) != nil else { throw CapabilityError(.invalidArgument, "Reference images must be PNG files.") }
        input.append(bytes)
      }
      let image = try await image(session, prompt, images: input, options: options)
      guard let header = PNGHeader(image) else {
        throw CapabilityError(.providerUnavailable, "The provider returned an image that is not a PNG.")
      }
      _ = try await place(image, at: destination, try await client(session))
      return GeneratedImage(path: destination.rendered, bytes: image.count, width: header.width, height: header.height)
    } catch {
      claims.release(destination)
      throw error
    }
  }

  // The answer main recorded for the client's tool call, when its write ran
  // before. It stands only for the destination written then: a retry that
  // names another is refused, not answered.
  private func receipt(_ recorded: SpaceClient, for destination: Address) async throws -> WriteOutput? {
    var query = URLComponents()
    query.queryItems = [URLQueryItem(name: "address", value: destination.rendered)]
    do { return try await recorded.api(.get, "/v1/receipt" + query.string!) }
    catch let failure as SpaceClient.ToolFailure where failure.error.code == .notFound { return nil }
    catch let failure as SpaceClient.ToolFailure where failure.error.code == .conflict { throw ToolProblem(failure.error.message) }
  }

  // A session home other than the caller's own, in its own group, is never
  // written; main refuses the rest at the write. Checked before the provider
  // is paid.
  private func refuseForeignHome(_ destination: Address, _ session: SessionID) async throws {
    guard case let .space(path, group) = destination, let target = try? SpacePath(validating: path), target.homeOwner != nil else { return }
    let context: DiscoveryContext = try await client(session).api(.get, "/v1/context")
    try SessionHome.refuseForeignWrite(to: target, in: group ?? context.group, by: session, home: context.group)
  }

  private func refuseExisting(_ destination: Address, _ session: SessionID) async throws {
    do {
      let _: JSONValue = try await client(session).tool("stat", .object(["path": .string(destination.rendered)]))
    } catch let failure as SpaceClient.ToolFailure where failure.error.code == .notFound {
      return
    }
    throw neverOverwrites(destination.rendered)
  }

  private func place(_ image: Data, at destination: Address, _ main: SpaceClient) async throws -> ToolResultPayload {
    do {
      let written: WriteOutput = try await main.putFileBytes(destination.rendered, image, ifMatch: nil, createOnly: true)
      return .write(.init(path: destination.rendered, revision: try revision(written.token, at: destination)))
    } catch let failure as SpaceClient.ToolFailure where failure.error.code == .conflict {
      throw neverOverwrites(destination.rendered)
    }
  }
}
