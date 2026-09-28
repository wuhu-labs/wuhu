import Foundation
@testable import MachineAgent
import Scratch
import Testing

@Suite
struct VaultTests {
  @Test func roundTripPersistsAcrossInstances() async throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let directory = scratch.path
    let vault = SecretVault(stateDirectory: URL(fileURLWithPath: directory))
    try await vault.set(name: "GH_TOKEN", value: "hunter2")
    try await vault.set(name: "NPM_TOKEN", value: "npm-value")
    #expect(try await vault.names() == ["GH_TOKEN", "NPM_TOKEN"])

    let reopened = SecretVault(stateDirectory: URL(fileURLWithPath: directory))
    #expect(try await reopened.names() == ["GH_TOKEN", "NPM_TOKEN"])
    try await reopened.remove(name: "GH_TOKEN")
    #expect(try await reopened.names() == ["NPM_TOKEN"])
    #expect(try await vault.names() == ["NPM_TOKEN"])
  }

  @Test func vaultFileIsOwnerOnly() async throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let directory = scratch.path
    let vault = SecretVault(stateDirectory: URL(fileURLWithPath: directory))
    try await vault.set(name: "A", value: "v")
    let attributes = try FileManager.default.attributesOfItem(atPath: directory + "/vault.json")
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
  }

  @Test func resolveInjectsAndRegistersMasking() async throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let vault = SecretVault(stateDirectory: scratch.url)
    try await vault.set(name: "TOKEN", value: "hunter2")
    try await vault.set(name: "EMPTY", value: "")
    let resolved = try await vault.resolve(["GITHUB_TOKEN": "TOKEN", "ALIAS": "TOKEN", "E": "EMPTY"])
    #expect(resolved.env == ["GITHUB_TOKEN": "hunter2", "ALIAS": "hunter2", "E": ""])
    #expect(resolved.maskedValues == ["hunter2"])
  }

  @Test func resolveUnknownSecretThrows() async throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let vault = SecretVault(stateDirectory: scratch.url)
    await #expect(throws: SecretVault.UnknownSecret.self) {
      _ = try await vault.resolve(["X": "NOPE"])
    }
  }
}
