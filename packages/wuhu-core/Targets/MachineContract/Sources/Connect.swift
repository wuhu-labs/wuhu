#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Contract
import JSONValue

public enum MachineConnect {
  public static let pubkeyHeader: String = "x-wuhu-machine-pubkey"
  public static let challengeHeader: String = "x-wuhu-machine-challenge"
  public static let signatureHeader: String = "x-wuhu-machine-signature"
  /// Comma-separated capabilities the dialing agent announces. Absent means an
  /// agent from before the header.
  public static let capabilitiesHeader: String = "x-wuhu-machine-capabilities"
  /// The agent takes `ExecStart.secretValues` and resolves no secret names itself.
  public static let groupSecrets: String = "group-secrets"

  // Domain separation: a machine-connect signature must never verify as any
  // other signed statement, so the payload carries its own context label.
  public static func signingPayload(challenge: String) -> Data {
    Data("wuhu-machine-connect:\(challenge)".utf8)
  }
}

@Contract
public struct MachineChallengeOutput: Codable, Equatable, Sendable {
  public let challenge: String
}
