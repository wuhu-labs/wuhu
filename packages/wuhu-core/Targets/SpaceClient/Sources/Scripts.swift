#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import FetchSSE
import enum SpaceContract.ScriptOutput
import struct SpaceContract.ScriptRunInput

extension SpaceClient {
  /// Runs `input` as a space script as this client's session (a session
  /// credential only). The outputs end when the script does; closing the
  /// connection kills it.
  public func runScript(_ input: ScriptRunInput) async throws -> some AsyncSequence<ScriptOutput, any Error> {
    var request = Request(url: try self.url("/v1/scripts"), method: .post)
    request.body = .bytes(try JSONEncoder().encode(input), contentType: "application/json")
    let response = try await self.observeFetch(request)
    guard 200 ..< 300 ~= response.status.code else {
      throw await Self.failure(from: response)
    }
    return response.sse().map { event in try JSONDecoder().decode(ScriptOutput.self, from: Data(event.data.utf8)) }
  }
}
