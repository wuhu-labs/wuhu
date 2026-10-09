#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Credentials.CredentialResolver
import Fetch
import struct InferenceKit.CapabilityError
import struct InferenceKit.CapabilityOptions
import JSONValue
import ServeRouting
import SpaceCore

func addCapabilityRoutes(_ router: inout Router, space: Space, credentials: CredentialResolver) {
  router.get("/v1/capabilities/:kind") { _, parameters in
    do {
      return try .json(try await spaceCapabilities(space: space, credentials: credentials).capability(parameters["kind"] ?? ""))
    } catch let error as CapabilityError { return capabilityFailure(error) }
  }
  router.post("/v1/web-search") { request, _ in
    do {
      let input = try await request.body?.json(SearchInput.self, upTo: 64 << 10)
      guard let input else { throw CapabilityError(.invalidArgument, "Search needs a JSON query.") }
      let result = try await spaceCapabilities(space: space, credentials: credentials).search(input.query, options: .init(provider: input.provider, count: input.count))
      return try .json(result)
    } catch let error as CapabilityError { return capabilityFailure(error) }
    catch { return capabilityFailure(.init(.invalidArgument, "Malformed web search request.")) }
  }
  router.post("/v1/image") { request, _ in
    do {
      let input = try await request.body?.json(ImageInput.self, upTo: 36 << 20)
      guard let input, (input.images?.count ?? 0) <= 5 else { throw CapabilityError(.invalidArgument, "Image requests need a prompt and at most five PNG references.") }
      let images = try (input.images ?? []).map { raw in
        guard let bytes = Data(base64Encoded: raw), bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), !bytes.isEmpty else { throw CapabilityError(.invalidArgument, "Image references must be base64 PNG bytes.") }
        return bytes
      }
      guard images.reduce(0, { $0 + $1.count }) <= 25 * 1024 * 1024 else { throw CapabilityError(.invalidArgument, "Image references exceed the 25 MiB aggregate bound.") }
      let result = try await spaceCapabilities(space: space, credentials: credentials).image(input.prompt, images: images, options: .init(provider: input.provider, model: input.model, quality: input.quality, size: input.size))
      guard result.count >= 24, result.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { throw CapabilityError(.providerUnavailable, "The provider returned an image that is not a PNG.") }
      return try .json(ImageOutput(b64JSON: result.base64EncodedString(), mimeType: "image/png"))
    } catch let error as CapabilityError { return capabilityFailure(error) }
    catch { return capabilityFailure(.init(.invalidArgument, "Malformed image request.")) }
  }
}

private struct SearchInput: Decodable {
  var query: String
  var provider: String?
  var count: Int?
}

private struct ImageInput: Decodable {
  var prompt: String
  var images: [String]?
  var provider: String?
  var model: String?
  var quality: String?
  var size: String?
}

private struct ImageOutput: Encodable {
  var b64JSON: String
  var mimeType: String
}
