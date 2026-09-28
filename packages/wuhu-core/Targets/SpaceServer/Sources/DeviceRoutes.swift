#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import Fetch
import struct MachineContract.MachineID
import Serve
import ServeRouting
import SpaceContract
import SpaceCore

func addDeviceRoutes(_ router: inout Router, space: Space, dev: Bool) {
  @Dependency(\.date) var dateGen

  // Registration is the app's every-connect call, authenticated by the device
  // key itself: the row it upserts is keyed by (account, installation), so a
  // reinstalled space folder adopts the device instead of orphaning it.
  router.put("/v1/device") { request, _ in
    let input = try await request.json(DeviceRegisterInput.self)
    guard case let .verified(credential) = try await bearerVerdict(
      request: request, space: space, now: dateGen.now,
    ), credential.key.capabilities.contains(.device) else {
      return errorResponse(.unauthorized, code: "unauthorized", message: "a device key is required to register a device")
    }
    do {
      let record = try await space.upsertDevice(
        pubkey: credential.key.pubkey,
        installation: input.installation,
        kind: input.kind,
        name: input.name,
      )
      return try Response.json(devicePayload(record))
    } catch let SpaceError.alreadyExists(pubkey) {
      return errorResponse(
        .conflict,
        code: "deviceKeyTaken",
        message: "this key already belongs to another device",
        hint: "one key is current for one device; \(pubkey) is registered elsewhere",
      )
    } catch let SpaceError.invalidDeviceKind(kind) {
      return errorResponse(
        .badRequest,
        code: "invalidArgument",
        message: "unknown device kind: \(kind)",
        hint: "one of: \(DeviceKind.allCases.map(\.rawValue).joined(separator: ", "))",
      )
    }
  }

  router.patch("/v1/device/:id") { request, parameters in
    let input = try await request.json(DeviceAnnotateInput.self)
    guard let id = parameters["id"], let record = try await space.device(id: id) else {
      return unknownDevice(parameters)
    }
    let actor: ManagementActor
    switch try await managementVerdict(request: request, space: space, dev: dev, now: dateGen.now) {
    case let .actor(resolved): actor = resolved
    case let .refused(response): return response
    }
    guard actor.mayManage(record.account) else {
      return errorResponse(.forbidden, code: "forbidden", message: "device \(id) belongs to another account")
    }
    var machine: MachineID?
    if let reference = input.machine {
      guard let resolved = try await space.resolveMachine(reference) else {
        return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(reference)")
      }
      machine = resolved.id
    }
    return try Response.json(devicePayload(try await space.annotateDevice(id, name: input.name, machine: machine)))
  }

  router.get("/v1/devices") { _, _ in
    try Response.json(DevicesOutput(devices: try await space.devices().map(devicePayload)))
  }

  router.post("/v1/device/:id/command") { request, parameters in
    let input = try await request.json(DeviceCommandInput.self)
    guard let id = parameters["id"] else { return unknownDevice(parameters) }
    let issuer: String
    switch try await bearerVerdict(request: request, space: space, now: dateGen.now) {
    case let .verified(credential):
      issuer = credential.key.account.rawValue
    case let .rejected(response):
      return response
    case .anonymous:
      guard dev else {
        return errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required")
      }
      issuer = "owner"
    }
    do {
      let n = try await space.issueDeviceCommand(
        device: id, payload: input.payload.jsonString(), issuedBy: issuer,
      )
      return try Response.json(DeviceCommandOutput(n: Int(n)))
    } catch is SpaceError {
      return unknownDevice(parameters)
    }
  }
}

func devicePayload(_ record: DeviceRecord) -> DevicePayload {
  DevicePayload(
    id: record.id,
    account: record.account.rawValue,
    kind: record.kind.rawValue,
    name: record.name,
    machine: record.machine?.rawValue,
    createdAt: record.createdAt.timeIntervalSince1970,
    lastSeenAt: record.lastSeenAt.timeIntervalSince1970,
  )
}

private func unknownDevice(_ parameters: RouteParameters) -> Response {
  errorResponse(.notFound, code: "notFound", message: "unknown device: \(parameters["id"] ?? "")")
}
