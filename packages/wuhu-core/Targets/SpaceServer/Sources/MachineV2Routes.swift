#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Assertion
import Dependencies
import Fetch
import FetchTunnel
import JSONValue
import MachineContract
import struct OperationProtocol.OperationError
import Serve
import ServeRouting
import struct SpaceContract.EnrollConsumeInput
import struct SpaceContract.EnrollConsumeOutput
import struct SpaceContract.GroupID
import SpaceCore

func addMachineV2Routes(_ router: inout Router, space: Space, hub: MachineV2Hub, upgrades: MachineV2Upgrades, fingerprint: String?, principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict) {
  let challenges = OneShotChallenges(prefix: "mv2_")
  @Sendable func enroll(_ input: MachineAddInput, pubkey: String, principal: Principal) async throws -> Response {
    guard let name = input.name, MachineName.normalized(name) != nil else {
      return errorResponse(.badRequest, code: "invalidMachineName", message: "Machine v2 enrollment requires a machine name")
    }
    let enrolledBy: AccountID?
    switch principal.actor {
    case let .person(_, account): enrolledBy = account
    case .anonymous: enrolledBy = nil
    case .session:
      guard input.device == nil else {
        return errorResponse(.forbidden, code: "forbidden", message: "Only a person links a machine to a device")
      }
      enrolledBy = nil
    }
    let group: GroupID
    switch try await machineRegistrationGroup(input.group, principal: principal, space: space) {
    case let .success(resolved): group = resolved
    case let .failure(response): return response
    }
    do {
      let enrolled = try await space.enrollMachineV2(name: name, group: group, pubkey: pubkey, device: input.device, enrolledBy: enrolledBy)
      return try Response.json(EnrollConsumeOutput(account: enrolled.key.account.rawValue, capabilities: enrolled.key.capabilities.map(\.rawValue).sorted(), machine: enrolled.machine.id.rawValue, machineName: enrolled.machine.name))
    } catch let SpaceError.machineNameTaken(name) {
      return errorResponse(.conflict, code: "machineNameTaken", message: "Machine name \(name) is already taken")
    } catch SpaceError.malformedPubkey {
      return errorResponse(.badRequest, code: "invalidArgument", message: "Malformed machine public key")
    } catch SpaceError.alreadyExists {
      return errorResponse(.conflict, code: "keyTaken", message: "This public key is already enrolled")
    } catch let SpaceError.unknownDevice(device) {
      return errorResponse(.notFound, code: "unknownDevice", message: "No device \(device) of yours")
    } catch let error as SpaceError {
      throw error
    } catch {
      return machineAuthUnavailable()
    }
  }

  router.post("/v1/machine-v2") { request, _ in
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(value): principal = value
    case let .refused(response): return response
    }
    let input = try await request.json(MachineAddInput.self)
    if let pubkey = input.pubkey {
      return try await enroll(input, pubkey: pubkey, principal: principal)
    }
    guard input.device == nil else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "A device link needs the machine's pubkey")
    }
    guard let name = input.name, let normalized = MachineName.normalized(name) else {
      return errorResponse(.badRequest, code: "invalidMachineName", message: "Invalid machine name")
    }
    let group: GroupID
    switch try await machineRegistrationGroup(input.group, principal: principal, space: space) {
    case let .success(resolved): group = resolved
    case let .failure(response): return response
    }
    let scope: ReachScope
    switch machineScope(input.scope) {
    case let .success(resolved): scope = resolved
    case let .failure(response): return response
    }
    do {
      let (machine, token) = try await space.addMachineV2(name: normalized, group: group, scope: scope)
      return try Response.json(MachineAddOutput(id: machine.id, token: token.token.rawValue, fingerprint: fingerprint, group: machine.group.rawValue))
    } catch let SpaceError.machineNameTaken(name) {
      return errorResponse(.conflict, code: "machineNameTaken", message: "Machine name \(name) is already taken")
    }
  }

  router.post("/v1/machine-v2/:id/revoke") { request, parameters in
    guard let credential = machineV2Credential(request, challenges: challenges), let id = parameters["id"], credential.machines == [id] else {
      return errorResponse(.unauthorized, code: "keyInvalid", message: "Machine v2 key handshake rejected")
    }
    await hub.revocationGate(MachineID(rawValue: id))
    let revoked: Bool
    do { revoked = try await space.revokeMachine(MachineID(rawValue: id), presenting: credential.pubkey) } catch { return machineAuthUnavailable() }
    guard revoked else {
      return errorResponse(.unauthorized, code: "machineNotAuthorized", message: "Not a live key of this Machine v2 identity")
    }
    await hub.kick(MachineID(rawValue: id))
    return jsonResponse(.object([:]))
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
    } catch let error as SpaceError {
      throw error
    } catch let error as OperationError {
      throw error
    } catch {
      return machineAuthUnavailable()
    }
  }
  // The key-signed reads a machine makes about itself: its hello (status plus
  // upgrade announcement) and the bare announcement.
  @Sendable func keySignedMachine(_ request: Request, _ parameters: RouteParameters) async -> Result<MachineRecord, ResponseFailure> {
    guard let credential = machineV2Credential(request, challenges: challenges), let id = parameters["id"], credential.machines == [id] else {
      return .failure(.init(errorResponse(.unauthorized, code: "keyInvalid", message: "Machine v2 key handshake rejected")))
    }
    if let refusal = await authorizationRefusal(hub, credential, message: "Not an enrolled Machine v2 identity") { return .failure(.init(refusal)) }
    let resolved: MachineRecord?
    do { resolved = try await space.resolveMachine(id) } catch { return .failure(.init(machineAuthUnavailable())) }
    guard let machine = resolved else {
      return .failure(.init(errorResponse(.unauthorized, code: "machineNotAuthorized", message: "Not an enrolled Machine v2 identity")))
    }
    return .success(machine)
  }
  router.get("/v1/machine-v2/:id/upgrade") { request, parameters in
    guard request.headers[MachineV2Connect.pubkeyHeader] != nil else {
      return errorResponse(.unauthorized, code: "keyInvalid", message: "The upgrade announcement is for the machine's own key")
    }
    switch await keySignedMachine(request, parameters) {
    case let .failure(failure): return failure.response
    case let .success(machine): return try Response.json(await upgrades.announcement(for: machine.id))
    }
  }
  router.get("/v1/machine-v2/:id") { request, parameters in
    if request.headers[MachineV2Connect.pubkeyHeader] != nil {
      switch await keySignedMachine(request, parameters) {
      case let .failure(failure): return failure.response
      case let .success(machine):
        return try await machineV2Status(space: space, machine: machine, upgrade: upgrades.announcement(for: machine.id))
      }
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
    return try await machineV2Status(space: space, machine: machine)
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
    var streams = TunnelLimits().streams
    if let advertised = request.headers[MachineV2Connect.tunnelStreamsHeader] {
      guard let value = Int(advertised), (1 ... MachineV2Connect.tunnelStreams).contains(value) else {
        return .response(errorResponse(.badRequest, code: "invalidTunnelStreams", message: "Tunnel streams must be 1 through \(MachineV2Connect.tunnelStreams)"))
      }
      streams = value
    }
    if let refusal = await authorizationRefusal(hub, credential, message: "Credential cannot serve the addressed machines") { return .response(refusal) }
    return .boundedWebSocket(limits: .init(), subprotocol: TunnelTransport.webSocketSubprotocol) { [streams] transport in
      await hub.run(credential, transport: transport, streams: streams)
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

// 401 tells a machine its key is dead and may be discarded; anything that is
// not a definitive refusal must stay retryable, or an outage destroys keys.
private func authorizationRefusal(_ hub: MachineV2Hub, _ credential: MachineV2Hub.Credential, message: String) async -> Response? {
  do {
    try await hub.authorize(credential)
    return nil
  } catch let error as OperationError where error.code == .machineNotAuthorized {
    return errorResponse(.unauthorized, code: "machineNotAuthorized", message: message)
  } catch {
    return machineAuthUnavailable()
  }
}

private func machineAuthUnavailable() -> Response {
  errorResponse(.serviceUnavailable, code: "machineAuthUnavailable", message: "Machine v2 authorization is temporarily unavailable; retry")
}

private struct MachineV2Status: Encodable {
  let id: MachineID
  let name: String?
  /// The group the machine belongs to, so an app machine can show where agents reach it.
  let group: String
  let attached: Bool
  let state: String
  let observedAt: Date?
  let reason: String?
  /// Only on the machine's own key-signed hello.
  let upgrade: MachineV2Upgrade?
}

private struct ResponseFailure: Error {
  let response: Response
  init(_ response: Response) { self.response = response }
}

private func machineV2Status(space: Space, machine: MachineRecord, upgrade: MachineV2Upgrade? = nil) async throws -> Response {
  let evidence = try await space.machineV2PresenceEvidence(machine.id.rawValue, group: machine.group)
  return try Response.json(MachineV2Status(id: machine.id, name: machine.name, group: machine.group.rawValue, attached: evidence?.state == .attached, state: evidence?.state.rawValue ?? "detached", observedAt: evidence?.observedAt, reason: evidence?.reason, upgrade: upgrade))
}
