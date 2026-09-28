import JSONValue
import struct SpaceContract.SecretsOutput

extension Executor {
  mutating func secretSet(name: String) async throws {
    let space = try self.wallet.pinnedSpace()
    if self.runner.stdinIsTerminal {
      await self.runner.stderr("value for \(name) (stdin, end with ctrl-d): ")
    }
    let value = try await self.runner.stdin().strippingOneTrailingLineEnding()
    let _: EmptyOutput = try await self.api(.put, "/v1/secret/\(name)", space: space, body: .object(["value": .string(value)]))
    await self.runner.stdout("set \(name)\n")
  }

  mutating func secretList() async throws {
    let space = try self.wallet.pinnedSpace()
    let output: SecretsOutput = try await self.api(.get, "/v1/secret", space: space)
    await self.runner.stdout(output.names.map { $0 + "\n" }.joined())
  }

  mutating func secretRemove(name: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let _: EmptyOutput = try await self.api(.delete, "/v1/secret/\(name)", space: space)
    await self.runner.stdout("removed \(name)\n")
  }
}
