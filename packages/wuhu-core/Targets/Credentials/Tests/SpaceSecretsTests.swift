#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Credentials
import Scratch
import Testing

private func withSecrets(_ body: (SpaceSecrets, URL) async throws -> Void) async throws {
  let directory = try scratchURL("secrets-tests")
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(SpaceSecretStores(configDirectory: directory, spaceID: "spc_test").group("shared"), directory)
}

@Suite struct SpaceSecretsTests {
  @Test func setListRemoveAndUse() async throws {
    try await withSecrets { secrets, _ in
      #expect(try await secrets.names() == [])
      try await secrets.set("GITHUB_TOKEN", to: "ghp_first")
      try await secrets.set("API_KEY", to: "sk-1")
      try await secrets.set("GITHUB_TOKEN", to: "ghp_second")
      #expect(try await secrets.names() == ["API_KEY", "GITHUB_TOKEN"])
      #expect(try await secrets.value(of: "GITHUB_TOKEN") == "ghp_second")
      try await secrets.remove("API_KEY")
      #expect(try await secrets.names() == ["GITHUB_TOKEN"])
      await #expect(throws: SecretError.unknown("API_KEY")) { try await secrets.remove("API_KEY") }
      await #expect(throws: SecretError.unknown("API_KEY")) { try await secrets.value(of: "API_KEY") }
    }
  }

  @Test func livesInTheConfigFolderReadableByItsOwnerOnly() async throws {
    try await withSecrets { secrets, directory in
      try await secrets.set("TOKEN", to: "value")
      #expect(secrets.file == directory.appendingPathComponent("secrets/spc_test/shared.json"))
      let fileMode = try FileManager.default.attributesOfItem(atPath: secrets.file.path)[.posixPermissions] as? Int
      let folderMode = try FileManager.default.attributesOfItem(
        atPath: secrets.file.deletingLastPathComponent().path,
      )[.posixPermissions] as? Int
      #expect(fileMode == 0o600)
      #expect(folderMode == 0o700)
    }
  }

  @Test func refusesBadNamesAndEmptyValues() async throws {
    try await withSecrets { secrets, _ in
      for name in ["", "1ST", "has-dash", "has space", "ünïcode", String(repeating: "A", count: 129)] {
        await #expect(throws: SecretError.invalidName(name)) { try await secrets.set(name, to: "v") }
      }
      try await secrets.set("_ok_2", to: "v")
      await #expect(throws: SecretError.emptyValue) { try await secrets.set("EMPTY", to: "") }
      #expect(try await secrets.names() == ["_ok_2"])
    }
  }

  @Test func eachGroupHasItsOwnFile() async throws {
    try await withSecrets { shared, directory in
      let stores = SpaceSecretStores(configDirectory: directory, spaceID: "spc_test")
      let alice = try stores.group("alice")
      try await alice.set("K", to: "alice-value")
      try await shared.set("K", to: "shared-value")
      #expect(alice.file == directory.appendingPathComponent("secrets/spc_test/alice.json"))
      #expect(try await alice.value(of: "K") == "alice-value")
      #expect(try await shared.value(of: "K") == "shared-value")
      try await alice.remove("K")
      await #expect(throws: SecretError.unknown("K")) { try await alice.value(of: "K") }
      #expect(try await shared.names() == ["K"])
    }
  }

  @Test func aGroupNeverNamesAPathOutsideTheSpacesFolder() {
    let stores = SpaceSecretStores(configDirectory: URL(fileURLWithPath: "/tmp/x"), spaceID: "spc_test")
    for group in ["", "../spc_other", "a/b", ".hidden", "-x"] {
      #expect(throws: SecretError.invalidGroup(group)) { try stores.group(group) }
    }
  }

  @Test func theFlatStoreFromBeforeGroupsNeedsAMove() async throws {
    try await withSecrets { _, directory in
      let stores = SpaceSecretStores(configDirectory: directory, spaceID: "spc_test")
      #expect(!stores.needsMove)
      try FileManager.default.createDirectory(at: directory.appendingPathComponent("secrets"), withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: directory.appendingPathComponent("secrets/spc_test.json"))
      #expect(stores.needsMove)
      #expect(stores.flatFile == directory.appendingPathComponent("secrets/spc_test.json"))
    }
  }
}
