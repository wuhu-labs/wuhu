import Foundation
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceServer
import Testing

// The app and the web decode this checked-in inspection body, so a change to
// the endpoint's encoding fails here before it reaches either client.
@Suite struct ModelRouteInspectionFixtureTests {
  static let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../SpaceContract/Tests/contract/model-route-inspection.json")

  static func inspection() throws -> SessionModelRouteOutput {
    let placed = Date(timeIntervalSince1970: 1_791_000_000)
    let failed = placed.addingTimeInterval(600)
    let evidence = [ModelPlacementEvidence(member: "primary", observedAt: placed.timeIntervalSince1970, windows: [
      .init(name: "five_hour", usedPercent: 99, resetsAt: placed.addingTimeInterval(18000).timeIntervalSince1970, capacity: 1, remaining: 0.01, score: 0.01),
    ], score: 0.01)]
    let created = SessionModelRoute(group: "fleet", member: "backup", specifier: .init(provider: "openai", model: "gpt-backup", effort: "medium"), bindingFingerprint: "fp-backup", epoch: "epoch-1", reason: .create, placedAt: placed, evidence: evidence)
    var waiting = SessionModelRoute(group: "fleet", member: "primary", specifier: .init(provider: "anthropic", model: "claude-primary", effort: "high"), bindingFingerprint: "fp-primary", epoch: "epoch-2", reason: .compaction, placedAt: placed.addingTimeInterval(60), evidence: evidence, switchCause: .quota)
    let history = [created, waiting]
    waiting.failure = ModelRouteFailure(reason: .quota, firstFailureAt: failed, deadline: failed.addingTimeInterval(1800), retryAt: failed.addingTimeInterval(3600), consecutiveFailures: 2, lastFailureAt: failed.addingTimeInterval(30))
    return SessionModelRouteOutput(
      requestedTarget: .object(["modelGroup": "fleet", "effort": "high"]),
      activeProvider: "anthropic", activeModel: "claude-primary",
      route: try modelRouteInspectionJSON(waiting),
      decisions: .array(try history.map(modelRouteInspectionJSON)),
    )
  }

  @Test func checkedInFixtureIsTheServerEncoding() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let encoded = String(decoding: try encoder.encode(Self.inspection()), as: UTF8.self) + "\n"
    let onDisk = try String(contentsOf: Self.fixture, encoding: .utf8)
    #expect(onDisk == encoded, "stale model-route-inspection.json; replace it with:\n\(encoded)")
  }
}
