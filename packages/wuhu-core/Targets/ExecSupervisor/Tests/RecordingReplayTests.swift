#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import FetchExchangeRecording
import struct OperationProtocol.OperationSnapshot
import Testing

@Suite struct RecordingReplayTests {
  @Test(arguments: ["backpressure", "daemon-detach", "process-group-stop", "agent-restart", "coordinator-cursor-handoff", "lease-expiry", "service-manager", "launchd-service-manager", "recovery-isolation"])
  func recordedAgentAnswersCarryTheOutputAndEvidence(_ name: String) async throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Recordings/" + name + ".json")
    let recording = try JSONDecoder().decode(ExchangeRecording.self, from: Data(contentsOf: url))
    var output = Data(); var committed: UInt64 = 0; var terminal: OperationSnapshot?
    for exchange in recording.exchanges where exchange.response.status == 200 {
      let address = try #require(URLComponents(string: exchange.request.url!))
      guard address.path.contains("/operations/"), !address.path.contains("/inputs/"), let body = exchange.response.body else { continue }
      let snapshot = try JSONDecoder().decode(OperationSnapshot.self, from: body)
      if snapshot.verdict != nil { terminal = snapshot }
      guard snapshot.channel == "stdout", let from = snapshot.from?.rawValue, let through = snapshot.through?.rawValue, through > committed else { continue }
      #expect(from <= committed)
      let data = try #require(snapshot.payload?.data)
      output.append(data.suffix(Int(through - committed)))
      committed = through
    }
    #expect(terminal?.verdict != nil)
    switch name {
    case "backpressure": #expect(output == Data(repeating: 0, count: 320_000))
    case "daemon-detach": #expect(output == Data("direct".utf8))
    case "agent-restart": #expect(output == Data("***hello-after-restart".utf8))
    case "coordinator-cursor-handoff": #expect(output == Data("coordinatortail".utf8))
    case "recovery-isolation": #expect(output == Data("recoverabletail".utf8))
    case "service-manager":
      #expect(output == Data(repeating: 0, count: 300_000) + Data("systemd-pending-input".utf8))
      let effect = try #require(recording.effects.first { $0.name == "systemdRestart" })
      #expect(effect.output["killMode"] == "process")
      // Recorded before exec workers replaced per-operation supervisors.
      #expect((effect.output["sameWorker"] ?? effect.output["sameSupervisor"]) == "True")
    case "launchd-service-manager":
      #expect(output == Data(repeating: 0, count: 300_000) + Data("launchd-pending-input".utf8))
      let effect = try #require(recording.effects.first { $0.name == "launchdRestart" })
      #expect(effect.output["abandonProcessGroup"] == "True")
      // Recorded before exec workers replaced per-operation supervisors.
      #expect((effect.output["sameWorker"] ?? effect.output["sameSupervisor"]) == "True")
      #expect(effect.output["fullStdout"] == "True")
      #expect(effect.output["pendingStdin"] == "True")
      let exact = try #require(recording.effects.first { $0.name == "outputExact" })
      #expect(exact.output["starts"] == "1")
    case "process-group-stop", "lease-expiry":
      #expect(terminal?.verdict?.tag == .stopped)
      #expect(terminal?.verdict?.result == ["termination": ["tag": "signal", "signal": 9]])
    default: Issue.record("Unknown fixture")
    }
    #expect(recording.effects.contains { $0.name == "buildProvenance" && $0.output["newAgent"]?.count == 40 })
  }
}
