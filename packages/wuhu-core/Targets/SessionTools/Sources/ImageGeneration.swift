#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import enum Credentials.ProviderCredential
import Dependencies
import Fetch
import struct InferenceKit.ModelsDocument
import SessionDomain
import struct SpaceCore.SessionHome
import enum SpaceCore.SpaceError
import struct SpaceFS.SpacePath
import Synchronization
import SystemFiles

private struct ImageGenerationRequest: Encodable {
  let prompt: String
  let model = "gpt-image-2"
  let n = 1
  let size = "1024x1024"
}

private struct ImageGenerationResponse: Decodable {
  struct Image: Decodable {
    let b64JSON: String

    enum CodingKeys: String, CodingKey {
      case b64JSON = "b64_json"
    }
  }

  let data: [Image]
}

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
    let image = try await renderImage(arguments.prompt)
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
  ) async throws -> GeneratedImage {
    let destination = try await resolve(raw, as: session)
    try claims.claim(destination)
    do {
      try await refuseUnwritable(destination, by: session)
      let image = try await renderImage(prompt)
      guard let header = PNGHeader(image) else {
        throw ToolProblem("image generation returned an image that is not a PNG")
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

  private func renderImage(_ prompt: String) async throws -> Data {
    let (_, modelsData) = try await space.fs(.shared).read(ModelsDocument.spacePath)
    let models = try ModelsDocument(json: modelsData)
    guard let (providerID, provider) = models.providers.first(where: { $0.value.dialect == .codex }) else {
      throw ToolProblem("image generation is not configured for this space")
    }
    guard case let .chatGPT(accessToken, accountID)? = try await credentials.resolve(providerID) else {
      throw ToolProblem("image generation requires a ChatGPT login for provider \(providerID)")
    }

    var headers = RequestHeaders()
    headers.setSensitive("authorization", "Bearer \(accessToken)")
    headers.setSensitive("chatgpt-account-id", accountID)
    headers.set("originator", provider.originator ?? "wuhu")
    let request = Request(
      url: provider.baseURL.appendingPathComponent("images/generations"),
      method: .post,
      headers: headers,
      body: try .json(ImageGenerationRequest(prompt: prompt)),
    )
    @Dependency(\.fetch) var fetch
    let response: Response
    do {
      response = try await fetch(request)
    } catch {
      throw ToolProblem("image generation request failed: \(error)")
    }
    guard response.status == .ok else {
      let body = try? await response.body.text(upTo: 512)
      throw ToolProblem("image generation failed with status \(response.status.code)\(body.map { ": \($0)" } ?? "")")
    }
    let payload: ImageGenerationResponse
    do {
      payload = try await response.body.json(ImageGenerationResponse.self, upTo: 8 << 20)
    } catch {
      throw ToolProblem("image generation returned an invalid response: \(error)")
    }
    guard let encoded = payload.data.first?.b64JSON,
          let image = Data(base64Encoded: encoded)
    else {
      throw ToolProblem("image generation returned no decodable image")
    }
    return image
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
