#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import JSONValue
import struct SpaceContract.ConversationPostOutput
import enum SpaceContract.MediaType

public struct PostedFile: Sendable {
  public var name: String
  public var bytes: Data

  public init(name: String, bytes: Data) {
    self.name = name
    self.bytes = bytes
  }
}

extension SpaceClient {
  // With files the post is multipart: the message's JSON in a part named
  // `message`, then one part named `file` per attachment, in order.
  public func postMessage(_ message: JSONValue, files: [PostedFile]) async throws -> ConversationPostOutput {
    guard !files.isEmpty else {
      return try await self.api(.post, "/v1/conversation/message", body: message)
    }
    var form = MultipartForm(boundary: "wuhu-\(UUID().uuidString)")
    form.appendField("message", message.jsonString(), contentType: "application/json")
    for file in files {
      form.appendFile(name: "file", filename: file.name, contentType: MediaType.of(path: file.name), bytes: file.bytes)
    }
    return try await self.api(.post, "/v1/conversation/message", form: form)
  }
}
