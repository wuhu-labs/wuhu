#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.ScriptRunInput

extension Executor {
  mutating func script(file: String, arguments: [String]) async throws {
    let url = URL(fileURLWithPath: file, relativeTo: URL(fileURLWithPath: self.runner.currentDirectory, isDirectory: true)).standardizedFileURL
    guard let data = try? Data(contentsOf: url), let source = String(data: data, encoding: .utf8) else {
      throw CLIError(message: "script: cannot read \(url.path) as UTF-8 text")
    }
    let space = try self.wallet.pinnedSpace()
    let outputs = try await self.authenticated(space, longRunning: true).runScript(ScriptRunInput(source: source, arguments: arguments))
    var resulted = false
    for try await output in outputs {
      switch output {
      case let .update(text):
        await self.runner.stdout(text + "\n")
      case let .result(text):
        resulted = true
        await self.runner.stdout(text + "\n")
      case let .failure(message):
        throw CLIError(message: message)
      case .end:
        guard resulted else { throw CLIError(message: "script: the run ended without a result") }
        return
      }
    }
    throw CLIError(message: "script: the server closed the stream before the run ended")
  }
}
