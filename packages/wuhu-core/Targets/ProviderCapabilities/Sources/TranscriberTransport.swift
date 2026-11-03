#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import Fetch

let diagnosticBodyLimit = 512

enum TranscriberTransport {
  static let userAgent = "wuhu-transcribe/1"

  static func boundary() -> String {
    @Dependency(\.uuid) var uuid
    return "----wuhu\(uuid().uuidString.replacingOccurrences(of: "-", with: ""))"
  }

  static func validate(_ clip: AudioClip) throws(TranscriptionError) {
    guard !clip.bytes.isEmpty else { throw .empty }
    guard clip.bytes.count <= TranscriptionLimits.maximumBytes else {
      throw .tooLarge(bytes: clip.bytes.count, limit: TranscriptionLimits.maximumBytes)
    }
  }

  static func send<T: Decodable & Sendable>(
    _ request: Request,
    decoding: T.Type,
  ) async throws(TranscriptionError) -> T {
    @Dependency(\.fetch) var fetch
    let response: Response
    do {
      response = try await fetch(request)
    } catch let error as FetchError {
      guard case let .transportFailure(kind) = error else {
        throw .transport("\(error)")
      }
      throw .transport(kind.rawValue)
    } catch {
      throw .transport("\(error)")
    }
    guard response.status.code == 200 else {
      let body = try? await response.body.text(upTo: diagnosticBodyLimit)
      throw .upstream(status: response.status.code, body: body)
    }
    do {
      return try await response.body.json(T.self)
    } catch {
      throw .malformedResponse("\(error)")
    }
  }
}
