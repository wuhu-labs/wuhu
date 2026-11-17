#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import GroupContract
import JSONValue
import MachineContract
import MachinesContract
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationError
import Serve
import ServeRouting
import struct ServerTelemetry.TraceParent
import SpaceHTTP
import SpaceIDs
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID
import TenancyContract

/// Who a machine route's request acts for, or the refusal the server's gate answered with.
public enum MachinePrincipalVerdict: Sendable {
  case caller(MachineCaller)
  case refused(Response)
}

// A machine belongs to one group; a principal uses it (lists, execs) when its
// group reads that group, and any other machine answers as unknown. Changing
// its name or its group takes an admin of the machine's group, and its keys a
// human one.
public func addMachineRoutes(
  _ router: inout Router,
  machines: Machines,
  hub: MachineHub,
  fingerprint: String?,
  callerOf: @escaping @Sendable (Request) async throws -> MachinePrincipalVerdict,
) {
  // The machine a route names, when the request's principal may use it.
  @Sendable func usable(_ request: Request, _ parameters: RouteParameters) async throws -> Admission<(MachineCaller, MachineRecord)> {
    let caller: MachineCaller
    switch try await callerOf(request) {
    case let .caller(resolved): caller = resolved
    case let .refused(response): return .failure(response)
    }
    guard let raw = parameters["id"], let record = try await machines.resolveMachine(raw, usableFrom: caller.group) else {
      return .failure(unknownMachine(parameters))
    }
    return .success((caller, record))
  }

  @Sendable func admits(_ caller: MachineCaller, of group: GroupID) async -> Bool {
    if case let .session(id) = caller.kind { return await machines.groups.roleOfSession(id, group) == .admin }
    if case let .person(_, account) = caller.kind { return await machines.groups.roleOfAccount(account, caller.group, group) == .admin }
    return false
  }

  @Sendable func humanAdmits(_ caller: MachineCaller, of group: GroupID) async -> Bool {
    guard let account = caller.account else { return false }
    return await machines.groups.isHumanAdmin(account, group)
  }

  // Each machine's device link, and when it was last seen if it is not attached now.
  @Sendable func status(of records: [MachineRecord]) async throws -> [MachineStatus] {
    let attached = await hub.attachedMachines()
    let links = await machines.tenancy.deviceLinks()
    var statuses: [MachineStatus] = []
    for record in records {
      let online = attached.contains(record.id)
      let evidence = online ? nil : try await machines.machineV2PresenceEvidence(record.id.rawValue, group: record.group)
      let lastSeen = evidence.flatMap { $0.reason == "neverAttached" ? nil : $0.observedAt.timeIntervalSince1970 }
      statuses.append(MachineStatus(
        id: record.id, name: record.name, group: record.group.rawValue, attached: online, scope: record.scope.rawValue,
        device: links[record.id], lastSeen: lastSeen,
      ))
    }
    return statuses
  }

  router.get("/v1/machine") { request, _ in
    let caller: MachineCaller
    switch try await callerOf(request) {
    case let .caller(resolved): caller = resolved
    case let .refused(response): return response
    }
    return try await Response.json(status(of: try await machines.machines(usableFrom: caller.group)))
  }

  router.get("/v1/machine/:id/status") { request, parameters in
    let record: MachineRecord
    switch try await usable(request, parameters) {
    case let .success((_, resolved)): record = resolved
    case let .failure(response): return response
    }
    return try await Response.json(status(of: [record])[0])
  }

  router.put("/v1/machine/:id/name") { request, parameters in
    let input = try await request.json(MachineNameInput.self)
    let record: MachineRecord
    switch try await usable(request, parameters) {
    case let .success((caller, resolved)):
      // The name is every group's handle on the machine: like a move, it is
      // its group's admins' to change.
      guard await admits(caller, of: resolved.group) else {
        return errorResponse(
          .forbidden, code: "adminRequired",
          message: "renaming machine \(resolved.name ?? resolved.id.rawValue) needs an admin of group \(resolved.group.rawValue)",
        )
      }
      record = resolved
    case let .failure(response): return response
    }
    do {
      let renamed = try await machines.renameMachine(record.id, name: input.name)
      return try await Response.json(status(of: [renamed])[0])
    } catch let SpaceError.invalidMachineName(raw) {
      return errorResponse(
        .badRequest,
        code: "invalidMachineName",
        message: "invalid machine name: \(raw)",
        hint: "machine names are 1-63 characters matching [a-z0-9][a-z0-9.-]*, compared case-insensitively",
      )
    } catch let SpaceError.machineNameTaken(name) {
      return errorResponse(.conflict, code: "machineNameTaken", message: "machine name \(name) is already taken")
    } catch let SpaceError.machineNameTakenByMachine(name) {
      return errorResponse(
        .conflict, code: "machineNameTaken",
        message: "machine name \(name) is already taken by a machine",
        hint: "delete it to free the name: wuhu machine delete \(name)",
      )
    }
  }

  router.post("/v1/machine/:id/rotate") { request, parameters in
    try request.requireNoBody()
    let record: MachineRecord
    switch try await usable(request, parameters) {
    case let .success((caller, resolved)):
      guard await humanAdmits(caller, of: resolved.group) else {
        return humanAdminRequired("rotating machine \(resolved.name ?? resolved.id.rawValue)'s key", group: resolved.group)
      }
      record = resolved
    case let .failure(response): return response
    }
    let minted = try await machines.rotateMachine(record.id)
    return try Response.json(MachineRotateOutput(token: minted.token.rawValue, fingerprint: fingerprint))
  }

  router.post("/v1/machine/:id/revoke") { request, parameters in
    try request.requireNoBody()
    let record: MachineRecord
    switch try await usable(request, parameters) {
    case let .success((caller, resolved)):
      guard await humanAdmits(caller, of: resolved.group) else {
        return humanAdminRequired("revoking machine \(resolved.name ?? resolved.id.rawValue)", group: resolved.group)
      }
      record = resolved
    case let .failure(response): return response
    }
    _ = try await machines.revokeMachine(record.id)
    return jsonResponse(.object([:]))
  }

  router.delete("/v1/machine/:id") { request, parameters in
    try request.requireNoBody()
    let caller: MachineCaller
    switch try await callerOf(request) {
    case let .caller(resolved): caller = resolved
    case let .refused(response): return response
    }
    guard let raw = parameters["id"], let record = try await machines.resolveMachine(raw) else { return unknownMachine(parameters) }
    guard await humanAdmits(caller, of: record.group) else {
      guard try await caller.readable().contains(record.group) else { return unknownMachine(parameters) }
      return humanAdminRequired("deleting machine \(record.name ?? record.id.rawValue)", group: record.group)
    }
    do {
      try await machines.deleteMachine(record.id, by: caller)
    } catch SpaceError.notFound { return unknownMachine(parameters) }
    catch SpaceError.groupForbidden { return humanAdminRequired("deleting machine", group: record.group) }
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
    let caller: MachineCaller
    switch try await callerOf(request) {
    case let .caller(resolved): caller = resolved
    case let .refused(response): return response
    }
    // An admin of the machine's group moves it from whichever group they act
    // in; anyone else sees only the machines their group may use.
    guard let raw = parameters["id"], let record = try await machines.resolveMachine(raw) else {
      return unknownMachine(parameters)
    }
    let admitted = await admits(caller, of: record.group)
    let readable = try await caller.readable().contains(record.group)
    guard admitted || readable else {
      return unknownMachine(parameters)
    }
    guard let target = await machines.tenancy.group(input.group) else {
      return errorResponse(.notFound, code: "unknownGroup", message: "this space has no group \(input.group)")
    }
    for group in [record.group, target] {
      if await admits(caller, of: group) { continue }
      return errorResponse(
        .forbidden, code: MachineAdminErrorCode.adminRequired.rawValue,
        message: "moving a machine needs an admin of both its group and the target; you are not an admin of \(group.rawValue)",
      )
    }
    let moved = try await machines.moveMachine(record.id, to: target)
    return try await Response.json(status(of: [moved])[0])
  }

  // The switch: its own group alone, or every group that can reach it. Like a
  // rename, it is the machine's group's admins' to change.
  router.put("/v1/machine/:id/scope") { request, parameters in
    let input: MachineScopeInput
    do {
      input = try await request.json(MachineScopeInput.self)
    } catch {
      return errorResponse(
        .badRequest, code: "invalidArgument",
        message: "expected a scope body {\"scope\": \"owner\" | \"reachable\"}: \(error)",
      )
    }
    let scope: ReachScope
    switch machineScope(input.scope) {
    case let .success(resolved): scope = resolved
    case let .failure(response): return response
    }
    let record: MachineRecord
    switch try await usable(request, parameters) {
    case let .success((caller, resolved)):
      guard await admits(caller, of: resolved.group) else {
        return errorResponse(
          .forbidden, code: MachineAdminErrorCode.adminRequired.rawValue,
          message: "switching machine \(resolved.name ?? resolved.id.rawValue) needs an admin of group \(resolved.group.rawValue)",
        )
      }
      record = resolved
    case let .failure(response): return response
    }
    let switched = try await machines.setMachineScope(record.id, scope: scope)
    return try await Response.json(status(of: [switched])[0])
  }

  router.post("/v1/exec") { request, _ in
    let input = try await request.json(ExecMintInput.self)
    let caller: MachineCaller
    switch try await callerOf(request) {
    case let .caller(resolved): caller = resolved
    case let .refused(response): return response
    }
    guard try await machines.resolveMachine(input.machine.rawValue, usableFrom: caller.group) != nil else {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
    }
    do {
      try await hub.requireExecKind(input.machine)
      let record = try await machines.reserveExec(machine: input.machine, group: caller.group)
      return try Response.json(ExecMintOutput(id: record.id))
    } catch let error as OperationError {
      return try Response.json(ErrorEnvelope(error), status: .unprocessableContent)
    } catch is SpaceError {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
    }
  }

  // An exec on a machine the principal may not use, or homed in a group it
  // does not read, is no exec at all.
  @Sendable func usableExec(_ request: Request, _ parameters: RouteParameters) async throws -> Admission<(record: ExecRecord, caller: MachineCaller)> {
    let caller: MachineCaller
    switch try await callerOf(request) {
    case let .caller(resolved): caller = resolved
    case let .refused(response): return .failure(response)
    }
    guard let id = execID(parameters), let record = try await machines.execRecord(id),
          try await machines.tenancy.reach(caller.group).contains(record.group),
          try await machines.resolveMachine(record.machine.rawValue, usableFrom: caller.group) != nil
    else { return .failure(unknownExec(parameters)) }
    return .success((record, caller))
  }

  router.get("/v1/exec") { request, _ in
    let caller: MachineCaller
    switch try await callerOf(request) {
    case let .caller(resolved): caller = resolved
    case let .refused(response): return response
    }
    let usable = Set(try await machines.machines(usableFrom: caller.group).map(\.id))
    let readable = await machines.tenancy.reach(caller.group)
    return try Response.json(
      try await machines.liveExecs().filter { usable.contains($0.machine) && readable.contains($0.group) }.map(execStatus(of:)),
    )
  }

  router.get("/v1/exec/:id") { request, parameters in
    switch try await usableExec(request, parameters) {
    case let .success(admitted): return try Response.json(execStatus(of: admitted.record))
    case let .failure(response): return response
    }
  }

  router.post("/v1/exec/:id/kill") { request, parameters in
    try request.requireNoBody()
    let id: ExecID
    switch try await usableExec(request, parameters) {
    case let .success(admitted): id = admitted.record.id
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
    let admitted: (record: ExecRecord, caller: MachineCaller)
    switch try await usableExec(request, parameters) {
    case let .success(resolved): admitted = resolved
    case let .failure(response): return .response(response)
    }
    guard let leg = ExecLeg(admitted.caller) else {
      return .response(errorResponse(.forbidden, code: "forbidden", message: "a page attaches to no exec"))
    }
    guard await hub.admitsCaller(admitted.record, leg: leg) else {
      return .response(errorResponse(.conflict, code: "execAttached", message: "exec \(admitted.record.id.rawValue) belongs to another caller"))
    }
    let trace = TraceParent.enclosing
    return .webSocket { socket in
      await hub.runCallerSession(admitted.record, socket: socket, leg: leg, trace: trace)
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
    toolCallID: record.toolCallID?.rawValue,
    killDelivered: record.killDelivered,
  )
}

enum Admission<Value> {
  case success(Value)
  case failure(Response)
}

func machineRegistrationGroup(_ requested: String?, caller: MachineCaller, machines: Machines) async -> Admission<GroupID> {
  let group: GroupID
  if let requested {
    guard let resolved = await machines.tenancy.group(requested) else {
      return .failure(errorResponse(.notFound, code: "unknownGroup", message: "this space has no group \(requested)"))
    }
    group = resolved
  } else {
    group = caller.group
  }
  var admitted = false
  if case let .session(id) = caller.kind { admitted = await machines.groups.roleOfSession(id, group) == .admin }
  if case let .person(_, account) = caller.kind { admitted = await machines.groups.roleOfAccount(account, caller.group, group) == .admin }
  guard admitted else {
    return .failure(errorResponse(
      .forbidden, code: "adminRequired", message: "adding a machine needs an admin of group \(group.rawValue)",
    ))
  }
  return .success(group)
}

func machineScope(_ raw: String?) -> Admission<ReachScope> {
  guard let raw else { return .success(.owner) }
  guard let scope = ReachScope(rawValue: raw) else {
    return .failure(errorResponse(
      .badRequest, code: "invalidArgument", message: "scope is owner or reachable, not \(raw)",
    ))
  }
  return .success(scope)
}

func humanAdminRequired(_ what: String, group: GroupID) -> Response {
  errorResponse(.forbidden, code: "adminRequired", message: "\(what) needs a human admin of group \(group.rawValue)")
}

func execID(_ parameters: RouteParameters) -> ExecID? {
  guard let raw = parameters["id"], ExecID.isValid(raw) else { return nil }
  return ExecID(rawValue: raw)
}

func unknownMachine(_ parameters: RouteParameters) -> Response {
  errorResponse(.notFound, code: "notFound", message: "unknown machine: \(parameters["id"] ?? "")")
}

func unknownExec(_ parameters: RouteParameters) -> Response {
  errorResponse(.notFound, code: "notFound", message: "unknown exec: \(parameters["id"] ?? "")")
}
