#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue

extension Executor {
  mutating func webSearch(query: String, provider: String?, count: Int?) async throws {
    let space = try wallet.pinnedSpace()
    let input = try JSONValueEncoder().encode(SearchInput(query: query, provider: provider, count: count))
    let output: JSONValue = try await authenticated(space, longRunning: true).api(.post, "/v1/web-search", body: input)
    await runner.stdout(output.jsonString() + "\n")
  }

  mutating func image(prompt: String, images: [String], destination: String, provider: String?, model: String?, quality: String?, size: String?) async throws {
    let space = try wallet.pinnedSpace()
    let target = localURL(destination)
    guard !FileManager.default.fileExists(atPath: target.path) else { throw CLIError(message: "image: destination exists; image never overwrites") }
    guard images.count <= 5 else { throw UsageError(message: "image: at most five references") }
    var totalBytes = 0
    let references = try images.map { path in
      let bytes = try Data(contentsOf: localURL(path))
      totalBytes += bytes.count
      guard totalBytes <= 25 * 1024 * 1024 else { throw UsageError(message: "image: references exceed 25 MiB aggregate") }
      return bytes.base64EncodedString()
    }
    let input = try JSONValueEncoder().encode(ImageInput(prompt: prompt, images: references, provider: provider, model: model, quality: quality, size: size))
    let output: ImageOutput = try await authenticated(space, longRunning: true).api(.post, "/v1/image", body: input)
    guard let bytes = Data(base64Encoded: output.b64JSON) else { throw CLIError(message: "image: server returned invalid PNG data") }
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: target, options: .withoutOverwriting)
    await runner.stdout(target.path + "\n")
  }

  private func localURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: runner.currentDirectory, isDirectory: true)).standardizedFileURL
  }
}

private struct SearchInput: Encodable {
  var query: String
  var provider: String?
  var count: Int?
}

private struct ImageInput: Encodable {
  var prompt: String
  var images: [String]
  var provider: String?
  var model: String?
  var quality: String?
  var size: String?
}

private struct ImageOutput: Decodable { var b64JSON: String }
