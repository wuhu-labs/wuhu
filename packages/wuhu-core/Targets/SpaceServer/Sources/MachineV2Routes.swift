#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Assertion
import Dependencies
import Fetch
import FetchTunnel
import MachineContract
import struct OperationProtocol.OperationError
import Serve
import ServeRouting
import struct SpaceContract.EnrollConsumeInput
import struct SpaceContract.EnrollConsumeOutput
import struct SpaceContract.GroupID
import SpaceCore

func addMachineV2Routes(_ router: inout Router, space: Space, hub: MachineV2Hub, fingerprint: String?, principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict) {
  let challenges = OneShotChallenges(prefix: "mv2_")
  router.post("/v1/machine-v2") { request, _ in
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(value): principal = value
    case let .refused(response): return response
    }
    let input = try await request.json(MachineAddInput.self)
    guard let name = input.name, let normalized = MachineName.normalized(name), normalized.hasSuffix("-v2") else {
      return errorResponse(.badRequest, code: "invalidMachineName", message: "Machine v2 requires its own name ending in -v2")
    }
    let group: GroupID = switch principal.actor {
    case let .person(_, account): try await space.ensurePersonalGroup(account: account)
    case .session: principal.group
    case .anonymous: .shared
    }
    do {
      let (machine, token) = try await space.addMachineV2(name: normalized, group: group)
      return try Response.json(MachineAddOutput(id: machine.id, token: token.token.rawValue, fingerprint: fingerprint))
    } catch let SpaceError.machineNameTaken(name) {
      return errorResponse(.conflict, code: "machineNameTaken", message: "Machine name \(name) is already taken")
    }
  }
  router.post("/v1/machine-v2/enroll") { request, _ in
    let input = try await request.json(EnrollConsumeInput.self)
    do {
      let key = try await space.consumeMachineV2JoinToken(JoinToken(rawValue: input.token), pubkey: input.pubkey)
      guard let machine = try await space.machine(account: key.account) else { throw OperationError(.unknownMachine) }
      return try Response.json(EnrollConsumeOutput(account: key.account.rawValue, capabilities: key.capabilities.map(\.rawValue).sorted(), machine: machine.id.rawValue, machineName: machine.name))
    } catch is JoinTokenRejected {
      return errorResponse(.unauthorized, code: "tokenInvalid", message: "Not a live Machine v2 enrollment token")
    } catch SpaceError.malformedPubkey {
      return errorResponse(.badRequest, code: "invalidArgument", message: "Malformed machine public key")
    }
  }
  router.get("/v1/machine-v2/:id") { request, parameters in
    if request.headers[MachineV2Connect.pubkeyHeader] != nil {
      guard let credential = machineV2Credential(request, challenges: challenges), let id = parameters["id"],
            credential.machines == [id], let machine = try await space.resolveMachine(id)
      else {
        return errorResponse(.unauthorized, code: "keyInvalid", message: "Machine v2 key handshake rejected")
      }
      do { try await hub.authorize(credential) } catch {
        return errorResponse(.unauthorized, code: "machineNotAuthorized", message: "Not an enrolled Machine v2 identity")
      }
      return try Response.json(MachineStatus(id: machine.id, name: machine.name, attached: false))
    }
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(value): principal = value
    case let .refused(response): return response
    }
    guard let id = parameters["id"], let machine = try await space.resolveMachine(id, usableFrom: principal.group),
          try await space.machineV2Members(group: machine.group).contains(machine.id.rawValue)
    else {
      return errorResponse(.notFound, code: "unknownMachine", message: "No enrolled Machine v2 identity")
    }
    return try Response.json(MachineStatus(id: machine.id, name: machine.name, attached: false))
  }
  router.get("/v1/machine-v2/challenge") { _, _ in
    try Response.json(MachineChallengeOutput(challenge: challenges.mint()))
  }
  router.webSocket("/v1/machine-v2/connect") { request, _ in
    guard request.headers["sec-websocket-protocol"]?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(TunnelTransport.webSocketSubprotocol) == true else {
      return .response(errorResponse(.badRequest, code: "unsupportedSubprotocol", message: "Machine v2 requires wuhu-fetch-tunnel.v1"))
    }
    guard let credential = machineV2Credential(request, challenges: challenges) else {
      return .response(errorResponse(.unauthorized, code: "keyInvalid", message: "Machine v2 key handshake rejected"))
    }
    do { try await hub.authorize(credential) } catch {
      return .response(errorResponse(.unauthorized, code: "machineNotAuthorized", message: "Credential cannot serve the addressed machines"))
    }
    return .boundedWebSocket(limits: .init(), subprotocol: TunnelTransport.webSocketSubprotocol) { transport in
      await hub.run(credential, transport: transport)
    }
  }
}

private func machineV2Credential(_ request: Request, challenges: OneShotChallenges) -> MachineV2Hub.Credential? {
  guard let pubkey = request.headers[MachineV2Connect.pubkeyHeader],
        let challenge = request.headers[MachineV2Connect.challengeHeader],
        let raw = request.headers[MachineV2Connect.machinesHeader], raw.utf8.count <= 4096,
        let signature = request.headers[MachineV2Connect.signatureHeader],
        challenges.take(challenge), let key = VerifyingKey(label: pubkey), let bytes = Data(base64Encoded: signature) else { return nil }
  let machines = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
  guard !machines.isEmpty, machines.count <= 32, Set(machines).count == machines.count, machines.allSatisfy(MachineID.isValid),
        key.isValidSignature(bytes, for: MachineV2Connect.signingPayload(challenge: challenge, machines: machines)) else { return nil }
  return .init(pubkey: pubkey, machines: Set(machines))
}
