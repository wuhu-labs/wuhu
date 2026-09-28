#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import Fetch
import Serve
import ServeRouting
import SpaceContract
import SpaceCore

func addAccountRoutes(_ router: inout Router, space: Space, dev: Bool) {
  @Dependency(\.date) var dateGen

  router.post("/v1/accounts") { request, _ in
    switch try await managementVerdict(request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response):
      return response
    case let .actor(actor):
      guard actor.isAdmin else {
        return adminRequired("creating an account")
      }
      let input = try await request.json(AccountCreateInput.self)
      do {
        let record = try await space.addAccount(kind: .human, name: input.name, admin: input.admin ?? false)
        return try Response.json(accountPayload(record))
      } catch let SpaceError.reservedAccountName(name) {
        return errorResponse(
          .badRequest,
          code: "reservedAccountName",
          message: "\(name) is reserved: unenrolled --dev seats act as the owner principal",
        )
      }
    }
  }

  router.get("/v1/accounts") { request, _ in
    switch try await managementVerdict(request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response):
      return response
    case let .actor(actor):
      guard actor.isAdmin else {
        return adminRequired("listing accounts")
      }
      let records = try await space.accounts()
      return try Response.json(AccountListOutput(accounts: records.map(accountPayload)))
    }
  }

  router.delete("/v1/accounts/:id") { request, parameters in
    guard let id = validAccountID(parameters) else { return malformedAccountID(parameters) }
    switch try await managementVerdict(request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response):
      return response
    case let .actor(actor):
      guard actor.isAdmin else {
        return adminRequired("removing an account")
      }
      guard let record = try await space.account(id), record.removedAt == nil else {
        return unknownAccount(id)
      }
      guard record.kind == .human else {
        return errorResponse(
          .conflict,
          code: "invalidArgument",
          message: "\(id.rawValue) is a \(record.kind.rawValue) account",
          hint: "a machine is removed through its own verb: wuhu machine revoke",
        )
      }
      do {
        let removed = try await space.removeAccount(id)
        return try Response.json(AccountRemoveOutput(keys: removed.keys, readSessions: removed.readSessions))
      } catch SpaceError.lastAdmin {
        return lastAdminRefusal(id)
      }
    }
  }

  router.post("/v1/accounts/:id/admin") { request, parameters in
    guard let id = validAccountID(parameters) else { return malformedAccountID(parameters) }
    switch try await managementVerdict(request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response):
      return response
    case let .actor(actor):
      guard actor.isAdmin else {
        return adminRequired("granting or revoking admin")
      }
      let input = try await request.json(AccountAdminInput.self)
      do {
        let record = try await space.setAdmin(id, admin: input.admin)
        return try Response.json(accountPayload(record))
      } catch SpaceError.notFound {
        return unknownAccount(id)
      } catch SpaceError.lastAdmin {
        return lastAdminRefusal(id)
      } catch SpaceError.notAPerson {
        return errorResponse(
          .badRequest,
          code: "invalidArgument",
          message: "\(id.rawValue) is not a person's account; only a person is an admin",
        )
      } catch let SpaceError.adminThroughGroup(account, groups) {
        return errorResponse(.conflict, code: "adminThroughGroup", message: adminThroughGroupMessage(account, groups))
      }
    }
  }
}

private func accountPayload(_ record: AccountRecord) -> AccountPayload {
  AccountPayload(
    id: record.id.rawValue,
    kind: record.kind.rawValue,
    name: record.name,
    admin: record.isAdmin,
    createdAt: record.createdAt.timeIntervalSince1970,
  )
}

private func validAccountID(_ parameters: RouteParameters) -> AccountID? {
  guard let raw = parameters["id"], AccountID.isValid(raw) else { return nil }
  return AccountID(rawValue: raw)
}

private func malformedAccountID(_ parameters: RouteParameters) -> Response {
  errorResponse(.badRequest, code: "invalidArgument", message: "malformed account id: \(parameters["id"] ?? "")")
}

private func unknownAccount(_ id: AccountID) -> Response {
  errorResponse(.notFound, code: "notFound", message: "unknown account: \(id.rawValue)")
}

private func lastAdminRefusal(_ id: AccountID) -> Response {
  errorResponse(
    .conflict,
    code: "lastAdmin",
    message: "\(id.rawValue) is the last admin; the space must keep one",
    hint: "appoint another admin first, or recover offline with the space folder: wuhu user add --space <folder> --admin (server stopped)",
  )
}
