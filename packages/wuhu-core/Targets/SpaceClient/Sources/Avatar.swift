#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch

extension SpaceClient {
  public func userAvatar(_ person: String) async throws -> Data? {
    let response = try await self.fetch(Request(url: try self.url("/v1/user/\(person)/avatar")))
    if response.status.code == 404 { return nil }
    guard response.status.code == 200 else { throw await Self.failure(from: response) }
    return try await response.data()
  }

  public func putUserAvatar(_ png: Data) async throws {
    var request = Request(url: try self.url("/v1/user/me/avatar"), method: .put)
    request.body = .bytes(png, contentType: "image/png")
    let response = try await self.fetch(request)
    guard response.status.code == 204 else { throw await Self.failure(from: response) }
  }
}
