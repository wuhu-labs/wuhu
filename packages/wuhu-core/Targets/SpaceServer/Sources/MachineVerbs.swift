import Fetch
import JSONValue
import MachineContract
import class MainHub.Hub
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationError
import Serve
import ServeRouting
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceTools

/// Who a gated request's machine verbs act for: a session, or an observer's
/// firing, in its group.
enum MachineUser: Sendable {
  case session(SessionID, group: GroupID)
  case observer(Observer)

  var caller: Caller {
    switch self {
    case let .session(id, _): .session(id)
    case let .observer(observer): .observer(observer)
    }
  }

  var group: GroupID {
    switch self {
    case let .session(_, group): group
    case let .observer(observer): observer.group
    }
  }

  var principal: Principal {
    switch self {
    case let .session(id, group): Principal(actor: .session(id), group: group)
    case let .observer(observer): observer.principal
    }
  }
}

// The machine verbs a session's and an observer's scripts share: the machines
// its group may use, their directories, and the execs a script mints. Only a
// session mints an exec outside a script (its exec tool's).
func addMachineRoutes(
  to router: inout Router,
  space: Space,
  hub: MachineHub,
  owner: Hub,
  machines: MachineSeam,
  routed: @escaping UpgradingHandler,
  user: @escaping @Sendable () -> MachineUser,
) {
  let forward: RouteHandler = { request, _ in
    switch try await routed(request) {
    case let .response(response): response
    case .webSocket, .boundedWebSocket: errorResponse(.forbidden, code: "forbidden", message: "not a socket route")
    }
  }
  let roster: @Sendable () async throws -> ToolResultPayload = {
    try await owner.answering(as: user().caller) { try await owner.machineRoster(user().group) }
  }
  @Sendable func ownsExec(_ parameters: RouteParameters) async -> Bool {
    guard let raw = parameters["id"], ExecID.isValid(raw) else { return false }
    return (try? await SpaceToolContext(space: space, principal: user().principal).ownExecStatus(raw)) != nil
  }

  // The roster is the hub's (its refusal when the server has no machine
  // backend, its attach state); the API's shape adds each machine's group.
  router.get("/v1/machine") { _, _ in
    let payload = try await roster()
    guard case let .machines(listed) = payload else { return hubRefusal(payload) }
    let groups = Dictionary(uniqueKeysWithValues: try await space.machines(usableFrom: user().group).map { ($0.id.rawValue, $0.group.rawValue) })
    return try Response.json(listed.machines.compactMap { listing in
      groups[listing.id].map { MachineStatus(id: MachineID(rawValue: listing.id), name: listing.name, group: $0, attached: listing.attached) }
    })
  }
  router.get("/v1/machine/:id/status") { _, parameters in
    guard let raw = parameters["id"], let record = try await space.resolveMachine(raw, usableFrom: user().group) else {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine")
    }
    let payload = try await roster()
    guard case let .machines(listed) = payload else { return hubRefusal(payload) }
    guard let listing = listed.machines.first(where: { $0.id == record.id.rawValue }) else {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine")
    }
    return try Response.json(MachineStatus(id: record.id, name: record.name, group: record.group.rawValue, attached: listing.attached, scope: record.scope.rawValue))
  }
  router.post("/v1/machine/:id/mkdir") { request, parameters in
    let id = MachineID(rawValue: parameters["id"] ?? "")
    guard case let .object(fields)? = JSONValue.parse(try await request.body?.text() ?? ""),
          case let .string(path)? = fields["path"], path.hasPrefix("/")
    else { return errorResponse(.badRequest, code: "invalidArgument", message: "mkdir takes an absolute path on the machine") }
    guard try await space.resolveMachine(id.rawValue, usableFrom: user().group) != nil else {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(id.rawValue)")
    }
    let result = try await MachineSeam.$caller.withValue(user().caller.session) { try await machines.vfs(id, .mkdir(path: path)) }
    switch result {
    case .ok: return jsonResponse(.object([:]))
    case let .error(error): return jsonResponse(machineFailure(error).payload, status: .unprocessableContent)
    default: return errorResponse(.unprocessableContent, code: "internal", message: "machine returned an unexpected mkdir result for \(path)")
    }
  }

  router.post("/v1/exec") { request, _ in
    let input = try await request.json(ExecMintInput.self)
    let caller = user().caller
    do {
      guard try await space.resolveMachine(input.machine.rawValue, usableFrom: user().group) != nil else {
        return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
      }
      try await hub.requireExecKind(input.machine)
      let record: ExecRecord
      if let script = input.script {
        // A script's process: owned by the script, released when it ends.
        record = try await space.mintScriptExec(machine: input.machine, caller: caller.name, script: script, group: user().group)
        await hub.noteMinted(record)
      } else if caller.session == nil {
        return errorResponse(.forbidden, code: "forbidden", message: "an observer's execs belong to its handler's script")
      } else if let callID = request.headers[ToolCallHeader.name] {
        let claim = try await space.claimExec(
          machine: input.machine, caller: caller.name,
          toolCallID: ToolCallID(rawValue: callID), spec: input.spec?.jsonString(),
        )
        record = claim.record
        if !claim.rejoined { await hub.noteMinted(record) }
      } else {
        record = try await space.mintExec(machine: input.machine, caller: caller.name)
        await hub.noteMinted(record)
      }
      return try Response.json(ExecMintOutput(id: record.id))
    } catch let error as OperationError {
      return try Response.json(ErrorEnvelope(error), status: .unprocessableContent)
    } catch is SpaceError {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
    }
  }
  router.delete("/v1/script-execs/:script") { _, parameters in
    guard let script = parameters["script"], !script.isEmpty else {
      return errorResponse(.notFound, code: "notFound", message: "unknown script")
    }
    try await space.releaseScriptExecs(script: script, caller: user().caller.name)
    return try Response.json([String: String]())
  }
  router.get("/v1/exec") { _, _ in
    try Response.json(try await SpaceToolContext(space: space, principal: user().principal).ownExecs())
  }
  router.get("/v1/exec/:id") { request, parameters in
    guard await ownsExec(parameters) else { return unknownExec(parameters) }
    return try await forward(request, parameters)
  }
  router.post("/v1/exec/:id/kill") { request, parameters in
    guard await ownsExec(parameters) else { return unknownExec(parameters) }
    if let id = parameters["id"], let record = try await space.execRecord(ExecID(rawValue: id)), record.terminal != nil {
      return errorResponse(.unprocessableContent, code: "alreadyEnded", message: "exec has already ended")
    }
    return try await forward(request, parameters)
  }
  router.webSocket("/v1/exec/:id") { request, parameters in
    guard await ownsExec(parameters) else { return .response(unknownExec(parameters)) }
    return try await routed(request)
  }
}
