#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import enum InferenceKit.TranscriptionLimits

let audioContentTypes: [String: String] = [
  "wav": "audio/wav",
  "mp3": "audio/mpeg",
  "mp4": "audio/mp4",
  "m4a": "audio/m4a",
  "webm": "audio/webm",
]

extension Executor {
  mutating func transcribe(file: String, language: String?) async throws {
    let space = try self.wallet.pinnedSpace()
    let url = URL(
      fileURLWithPath: file,
      relativeTo: URL(fileURLWithPath: self.runner.currentDirectory, isDirectory: true),
    ).standardizedFileURL
    guard let contentType = audioContentTypes[url.pathExtension.lowercased()] else {
      throw UsageError(message: """
      transcribe: unknown audio extension "\(url.pathExtension)"; \
      expected one of \(audioContentTypes.keys.sorted().joined(separator: ", "))
      """)
    }
    let audio: Data
    do {
      audio = try Data(contentsOf: url)
    } catch {
      throw CLIError(message: "transcribe: cannot read \(url.path)")
    }
    guard audio.count <= TranscriptionLimits.maximumBytes else {
      throw CLIError(message: """
      transcribe: \(url.lastPathComponent) is \(audio.count) bytes; \
      a space accepts at most \(TranscriptionLimits.maximumBytes)
      """)
    }
    let output = try await self.authenticated(space)
      .transcribe(audio, contentType: contentType, language: language)
    await self.runner.stdout(output.text + "\n")
  }

  mutating func transcriber() async throws {
    let space = try self.wallet.pinnedSpace()
    let info = try await self.authenticated(space).transcriber()
    guard info.available, let provider = info.provider, let model = info.model else {
      await self.runner.stdout("no transcriber\n")
      return
    }
    await self.runner.stdout("\(provider) \(model)\n")
  }
}
