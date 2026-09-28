import Dependencies
import Foundation
import Scratch
@testable import SpaceServer
import Testing

@Suite struct ClaudeCodeRunTests {
  private func scratch() throws -> URL {
    try scratchURL("runs")
  }

  // Two servers of one space on one host: the second must leave every folder
  // of the first alone.
  @Test func aSecondRunOfTheSameSpaceTouchesNothingOfTheFirst() throws {
    let config = try scratch()
    defer { try? FileManager.default.removeItem(at: config) }
    let first = try ClaudeCodeRun.claim(configDirectory: config, spaceID: "spc_one")
    let live = first.activations + "/a1/work"
    try FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)

    let second = try ClaudeCodeRun.claim(configDirectory: config, spaceID: "spc_one")
    _ = ClaudeCodeHost(
      space: try .inMemory(), credentials: .unavailable, usage: UsageBoard(),
      configDirectory: config, origin: "https://space", spaceID: "spc_one",
    )

    #expect(second.folder != first.folder)
    #expect(FileManager.default.fileExists(atPath: live))
    #expect(first.folder.hasPrefix(config.appendingPathComponent("runs/spc_one").path))
    #expect(first.activations == first.folder + "/claude")
  }

  @Test func theRunLockIsHeldForTheRunsLifetime() throws {
    let config = try scratch()
    defer { try? FileManager.default.removeItem(at: config) }
    let run = try ClaudeCodeRun.claim(configDirectory: config, spaceID: "spc_one")
    let fd = open(run.folder + "/lock", O_RDWR)
    defer { close(fd) }
    #expect(fd >= 0)
    #expect(flock(fd, LOCK_EX | LOCK_NB) != 0, "another holder cannot take a live run's lock")
  }

  @Test func runIdentifiersAreVersionSevenAndSortByTime() {
    let early = withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1_790_000_000))
      $0.uuid = .incrementing
    } operation: { runIdentifier() }
    let late = withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1_790_000_001))
      $0.uuid = .incrementing
    } operation: { runIdentifier() }
    #expect(early.uuidString.lowercased().dropFirst(14).first == "7")
    #expect(early.uuidString < late.uuidString)
  }
}
