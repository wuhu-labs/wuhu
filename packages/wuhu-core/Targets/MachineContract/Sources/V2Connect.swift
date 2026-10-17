#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum MachineV2Connect {
  public static let pubkeyHeader = "x-wuhu-machine-v2-key"
  public static let challengeHeader = "x-wuhu-machine-v2-challenge"
  public static let signatureHeader = "x-wuhu-machine-v2-signature"
  public static let machinesHeader = "x-wuhu-machine-v2-machines"
  /// Sent on the connect upgrade: how many concurrent tunnel streams this agent's receiver admits, as a decimal.
  public static let tunnelStreamsHeader = "x-wuhu-machine-v2-tunnel-streams"
  public static let tunnelStreams = 1024

  public static func signingPayload(challenge: String, machines: [String]) -> Data {
    Data(("wuhu-machine-v2-tunnel-connect.v1\n" + challenge + "\n" + machines.sorted().joined(separator: "\n")).utf8)
  }
}
