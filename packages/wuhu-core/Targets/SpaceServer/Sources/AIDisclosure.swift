#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue
import struct SpaceContract.AIDisclosure
import struct SpaceContract.AIProviderDisclosure
import struct WuhuVFS.VFSPath
import protocol WuhuVFS.VirtualFileSystem

public enum AIDisclosureError: Error, Equatable, CustomStringConvertible {
  case unreadable(file: String)
  case invalid(file: String)

  public var description: String {
    switch self {
    case let .unreadable(file):
      "serve: --ai-disclosure cannot read \(file)"
    case let .invalid(file):
      "serve: --ai-disclosure invalid JSON in \(file); expected a nonempty version and providers with nonempty name, location, via and an absolute HTTPS policy URL"
    }
  }
}

func loadAIDisclosure(from fs: any VirtualFileSystem, path: String, file: String) async throws -> AIDisclosure {
  let data: Data
  do {
    data = try await fs.readData(at: VFSPath(absoluteFilePath: path))
  } catch {
    throw AIDisclosureError.unreadable(file: file)
  }
  do {
    let disclosure = try JSONDecoder().decode(AIDisclosure.self, from: data)
    guard !disclosure.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !disclosure.providers.isEmpty,
          disclosure.providers.allSatisfy(validProvider)
    else { throw AIDisclosureError.invalid(file: file) }
    return disclosure
  } catch {
    throw AIDisclosureError.invalid(file: file)
  }
}

private func validProvider(_ provider: AIProviderDisclosure) -> Bool {
  guard [provider.name, provider.location, provider.via].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
        let policy = URLComponents(string: provider.policy),
        policy.scheme == "https", let host = policy.host, !host.isEmpty,
        policy.user == nil, policy.password == nil
  else { return false }
  return true
}

func aiDisclosureJSON(_ disclosure: AIDisclosure) -> JSONValue {
  .object([
    "version": .string(disclosure.version),
    "providers": .array(disclosure.providers.map { provider in
      .object([
        "name": .string(provider.name),
        "location": .string(provider.location),
        "via": .string(provider.via),
        "policy": .string(provider.policy),
      ])
    }),
  ])
}
