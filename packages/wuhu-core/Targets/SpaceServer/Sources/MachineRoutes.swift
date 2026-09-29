#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Assertion
import Dependencies
import Fetch
import JSONValue
import MachineContract
import Serve
import ServeRouting
import struct SpaceContract.GroupID
import SpaceCore

// A machine belongs to one group; a principal uses it (lists, execs) when its
// group reads that group, and any other machine answers as unknown. Changing
// its name or its group takes an admin of the machine's group, and its keys a
// human one.
func addMachineRoutes(
  _ router: inout Router,
  space: Space,
  hub: MachineHub,
  challenges: OneShotChallenges,
  fingerprint: String?,
  principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict,
) {
  @Dependency(\.date) var dateGen
  // The machine a route names, when the request's principal may use it.
  @Sendable func usable(_ request: Request, _ parameters: RouteParameters) async throws -> Admission<(Principal, MachineRecord)> {
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return .failure(response)
    }
    guard let raw = parameters["id"], let record = try await space.resolveMachine(raw, usableFrom: principal.group) else {
      return .failure(unknownMachine(parameters))
    }
    return .success((principal, record))
  }

  router.post("/v1/machine") { request, _ in
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    // A person's machine joins their own group; the --dev seat's joins shared.
    let group: GroupID = switch principal.actor {
    case let .person(_, account): try await space.ensurePersonalGroup(account: account)
    case .session: principal.group
    case .anonymous: .shared
    }
    let name: String?
    if request.body != nil {
      name = try await request.json(MachineAddInput.self).name
    } else {
      name = nil
    }
    let added: MachineRecord
    do {
      added = try await space.addMachine(name: name, group: group)
    } catch let SpaceError.invalidMachineName(raw) {
      return errorResponse(.badRequest, code: "invalidMachineName", message: "invalid machine name: \(raw)")
    } catch let SpaceError.machineNameTaken(taken) {
      return errorResponse(.conflict, code: "machineNameTaken", message: "machine name \(taken) is already taken")
    }
    let minted = try await space.mintJoinToken(
      account: added.account,
      capabilities: [.execMachine],
      createdBy: nil,
      lifetime: machineJoinTokenLifetime,
    )
    return try Response.json(MachineAddOutput(id: added.id, token: minted.token.rawValue, fingerprint: fingerprint))
  }

  router.get("/v1/machine") { request, _ in
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    let attached = await hub.attachedMachines()
    let statuses = try await space.machines(usableFrom: principal.group).map { record in
      MachineStatus(id: record.id, name: record.name, attached: attached.contains(record.id))
    }
    return try Response.json(statuses)
  }

  router.put("/v1/machine/:id/name") { request, parameters in
    let input = try await request.json(MachineNameInput.self)
    let record: MachineRecord
    switch try await usable(request, parameters) {
    case let .success((principal, resolved)):
      // The name is every group's handle on the machine: like a move, it is
      // its group's admins' to change.
      guard try await admits(principal, of: resolved.group, space: space) else {
        return errorResponse(
          .forbidden, code: "adminRequired",
          message: "renaming machine \(resolved.name ?? resolved.id.rawValue) needs an admin of group \(resolved.group.rawValue)",
        )
      }
      record = resolved
    case let .failure(response): return response
    }
    do {
      let renamed = try await space.renameMachine(record.id, name: input.name)
      return try Response.json(MachineStatus(
        id: renamed.id, name: renamed.name, attached: await hub.attachedMachines().contains(renamed.id),
      ))
    } catch let SpaceError.invalidMachineName(raw) {
      return errorResponse(
        .badRequest,
        code: "invalidMachineName",
        message: "invalid machine name: \(raw)",
        hint: "machine names are 1-63 characters matching [a-z0-9][a-z0-9.-]*, compared case-insensitively",
      )
    } catch let SpaceError.machineNameTaken(name) {
      return errorResponse(.conflict, code: "machineNameTaken", message: "machine name \(name) is already taken")
    }
  }

  // rotate = kick + re-enroll: the live key rows die (dropping any open
  // connection) and a fresh join token invites the box's next key.
  router.post("/v1/machine/:id/rotate") { request, parameters in
    try request.requireNoBody()
    let record: MachineRecord
    switch try await usable(request, parameters) {
    case let .success((principal, resolved)):
      guard try await humanAdmits(principal, of: resolved.group, space: space) else {
        return humanAdminRequired("rotating machine \(resolved.name ?? resolved.id.rawValue)'s key", group: resolved.group)
      }
      record = resolved
    case let .failure(response): return response
    }
    _ = try await space.resetCredentials(account: record.account)
    await hub.kickMachine(record.id)
    let minted = try await space.mintJoinToken(
      account: record.account,
      capabilities: [.execMachine],
      createdBy: nil,
      lifetime: machineJoinTokenLifetime,
    )
    return try Response.json(MachineRotateOutput(token: minted.token.rawValue, fingerprint: fingerprint))
  }

  router.post("/v1/machine/:id/revoke") { request, parameters in
    try request.requireNoBody()
    let record: MachineRecord
    switch try await usable(request, parameters) {
    case let .success((principal, resolved)):
      guard try await humanAdmits(principal, of: resolved.group, space: space) else {
        return humanAdminRequired("revoking machine \(resolved.name ?? resolved.id.rawValue)", group: resolved.group)
      }
      record = resolved
    case let .failure(response): return response
    }
    _ = try await space.resetCredentials(account: record.account)
    await hub.kickMachine(record.id)
    return jsonResponse(.object([:]))
  }

  // A move needs an admin of both the group it leaves and the one it joins.
  // The machine's notes move into the new group's tree in the same revision.
  router.put("/v1/machine/:id/group") { request, parameters in
    let input: MachineMoveInput
    do {
      input = try await request.json(MachineMoveInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a machine-move body {\"group\": ...}: \(error)")
    }
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    // An admin of the machine's group moves it from whichever group they act
    // in; anyone else sees only the machines their group may use.
    guard let raw = parameters["id"], let record = try await space.resolveMachine(raw) else {
      return unknownMachine(parameters)
    }
    let admitted = try await admits(principal, of: record.group, space: space)
    let readable = try await space.reads(principal.group).contains(record.group)
    guard admitted || readable else {
      return unknownMachine(parameters)
    }
    let target = GroupID(rawValue: input.group)
    guard try await space.groupExists(target) else {
      return errorResponse(.notFound, code: "unknownGroup", message: "this space has no group \(input.group)")
    }
    for group in [record.group, target] {
      if try await admits(principal, of: group, space: space) { continue }
      return errorResponse(
        .forbidden, code: "adminRequired",
        message: "moving a machine needs an admin of both its group and the target; you are not an admin of \(group.rawValue)",
      )
    }
    let moved = try await space.moveMachine(record.id, to: target)
    return try Response.json(MachineStatus(
      id: moved.id, name: moved.name, attached: await hub.attachedMachines().contains(moved.id),
    ))
  }

  router.get("/v1/machine/challenge") { _, _ in
    try Response.json(MachineChallengeOutput(challenge: challenges.mint()))
  }

  // The signature gate: the box proves possession of its enrolled key by
  // signing a server-minted one-shot challenge; the pubkey resolves through
  // the live key row, so a revoked key is refused at the door.
  router.webSocket("/v1/machine/connect") { request, _ in
    guard let pubkey = request.headers[MachineConnect.pubkeyHeader],
          let challenge = request.headers[MachineConnect.challengeHeader],
          let signature = request.headers[MachineConnect.signatureHeader],
          challenges.take(challenge),
          verifiedConnectSignature(pubkey: pubkey, challenge: challenge, signature: signature),
          let machine = try await space.machine(pubkey: pubkey)
    else {
      return .response(errorResponse(.unauthorized, code: "keyInvalid", message: "machine key handshake rejected"))
    }
    let capabilities = Set((request.headers[MachineConnect.capabilitiesHeader] ?? "").split(separator: ",").map(String.init))
    return .webSocket { socket in
      await hub.runMachineSession(machine, pubkey: pubkey, capabilities: capabilities, socket: socket)
    }
  }

  router.post("/v1/exec") { request, _ in
    let input = try await request.json(ExecMintInput.self)
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    guard try await space.resolveMachine(input.machine.rawValue, usableFrom: principal.group) != nil else {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
    }
    do {
      let record = try await space.mintExec(machine: input.machine, group: principal.group)
      await hub.noteMinted(record)
      return try Response.json(ExecMintOutput(id: record.id))
    } catch is SpaceError {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
    }
  }

  // An exec on a machine the principal may not use, or homed in a group it
  // does not read, is no exec at all.
  @Sendable func usableExec(_ request: Request, _ parameters: RouteParameters) async throws -> Admission<ExecRecord> {
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return .failure(response)
    }
    guard let id = execID(parameters), let record = try await space.execRecord(id),
          try await space.reads(principal.group).contains(record.group),
          try await space.resolveMachine(record.machine.rawValue, usableFrom: principal.group) != nil
    else { return .failure(unknownExec(parameters)) }
    return .success(record)
  }

  router.get("/v1/exec") { request, _ in
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    let usable = Set(try await space.machines(usableFrom: principal.group).map(\.id))
    let readable = try await space.reads(principal.group)
    return try Response.json(
      try await space.liveExecs().filter { usable.contains($0.machine) && readable.contains($0.group) }.map(execStatus(of:)),
    )
  }

  router.get("/v1/exec/:id") { request, parameters in
    switch try await usableExec(request, parameters) {
    case let .success(record): return try Response.json(execStatus(of: record))
    case let .failure(response): return response
    }
  }

  router.post("/v1/exec/:id/kill") { request, parameters in
    try request.requireNoBody()
    let id: ExecID
    switch try await usableExec(request, parameters) {
    case let .success(record): id = record.id
    case let .failure(response): return response
    }
    do {
      try await hub.kill(id)
      return jsonResponse(.object([:]))
    } catch is MachineHubError {
      return unknownExec(parameters)
    }
  }

  router.webSocket("/v1/exec/:id") { request, parameters in
    let record: ExecRecord
    switch try await usableExec(request, parameters) {
    case let .success(resolved): record = resolved
    case let .failure(response): return .response(response)
    }
    return .webSocket { socket in
      await hub.runCallerSession(record, socket: socket)
    }
  }
}

func execStatus(of record: ExecRecord) -> ExecStatus {
  let state: ExecState = switch record.terminal {
  case nil: .live
  case let .exited(code): .exited(code: code)
  case let .signaled(signal): .signaled(signal: signal)
  case .cancelled: .cancelled
  case .reaped: .reaped
  case .machineLost: .machineLost
  }
  return ExecStatus(
    id: record.id,
    machine: record.machine,
    command: record.command,
    startedAt: record.startedAt.timeIntervalSince1970,
    state: state,
  )
}

private let machineJoinTokenLifetime: TimeInterval = 3600

private func verifiedConnectSignature(pubkey: String, challenge: String, signature: String) -> Bool {
  guard let key = VerifyingKey(label: pubkey),
        let signatureBytes = Data(base64Encoded: signature)
  else { return false }
  return key.isValidSignature(signatureBytes, for: MachineConnect.signingPayload(challenge: challenge))
}

private enum Admission<Value> {
  case success(Value)
  case failure(Response)
}

// The --dev seat is unrestricted.
private func admits(_ principal: Principal, of group: GroupID, space: Space) async throws -> Bool {
  principal.actor == .anonymous ? true : try await space.isAdmin(principal.actor, of: group)
}

// What can't be undone takes a person: a human admin of the group, or the --dev seat.
private func humanAdmits(_ principal: Principal, of group: GroupID, space: Space) async throws -> Bool {
  switch principal.actor {
  case .anonymous: true
  case let .person(_, account): try await space.isHumanAdmin(account, of: group)
  case .session: false
  }
}

private func humanAdminRequired(_ what: String, group: GroupID) -> Response {
  errorResponse(.forbidden, code: "adminRequired", message: "\(what) needs a human admin of group \(group.rawValue)")
}

private func execID(_ parameters: RouteParameters) -> ExecID? {
  guard let raw = parameters["id"], ExecID.isValid(raw) else { return nil }
  return ExecID(rawValue: raw)
}

private func unknownMachine(_ parameters: RouteParameters) -> Response {
  errorResponse(.notFound, code: "notFound", message: "unknown machine: \(parameters["id"] ?? "")")
}

func unknownExec(_ parameters: RouteParameters) -> Response {
  errorResponse(.notFound, code: "notFound", message: "unknown exec: \(parameters["id"] ?? "")")
}
