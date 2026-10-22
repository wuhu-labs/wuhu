import JSONValue
import SpaceClient
import struct SpaceContract.AccountListOutput
import struct SpaceContract.AccountPayload
import struct SpaceContract.AccountRemoveOutput
import struct SpaceContract.EnrollMintOutput
import struct SpaceContract.KeyListOutput
import struct SpaceContract.ServerInfo
import struct SpaceContract.UserPayload
import struct SpaceContract.UsersOutput

extension Executor {
  mutating func userAdd(name: String, admin: Bool, ttl: Int?, guest: Bool = false) async throws {
    let space = try self.wallet.pinnedSpace()
    let client = try await self.authenticated(space, requiringPerson: true)
    let info: ServerInfo = try await client.api(.get, "/v1/server")
    var body: JSONValue = .object(["name": .string(name), "admin": .bool(admin)])
    if guest { body.set("guest", .bool(true)) }
    let account: AccountPayload = try await client.api(.post, "/v1/accounts", body: body)
    await self.runner.stdout("account \(account.id) (\(name))\(account.admin ? " admin" : "")\(account.guest == true ? " guest" : "")\n")
    try await self.printUserInvite(account: account.id, ttl: ttl, client: client, server: info.origin ?? client.base)
  }

  mutating func userInvite(account: String, ttl: Int?) async throws {
    let space = try self.wallet.pinnedSpace()
    let client = try await self.authenticated(space, requiringPerson: true)
    let info: ServerInfo = try await client.api(.get, "/v1/server")
    try await self.printUserInvite(account: account, ttl: ttl, client: client, server: info.origin ?? client.base)
  }

  mutating func userAdmin(account: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let client = try await self.authenticated(space, requiringPerson: true)
    let output: AccountPayload = try await client.api(.post, "/v1/accounts/\(account)/admin", body: .object([
      "admin": .bool(true),
    ]))
    await self.runner.stdout("account \(output.id) admin\n")
  }

  private mutating func printUserInvite(account: String, ttl: Int?, client: SpaceClient, server: String) async throws {
    var body: JSONValue = .object([
      "account": .string(account), "capabilities": .array([.string("device")]),
    ])
    body.set("ttlSeconds", ttl.map(JSONValue.integer))
    let output: EnrollMintOutput = try await client.api(.post, "/v1/enroll", body: body)
    let envelope = EnrollmentEnvelope(server: server, token: output.token, space: output.space, fingerprint: output.fingerprint)
    await self.runner.stdout(envelope.url + "\n")
    await self.runner.stderr("one-time link; it dies at first use or in \(ttl ?? 3600) seconds\n")
  }

  mutating func userHandle(handle: String, displayName: String?) async throws {
    let space = try self.wallet.pinnedSpace()
    var body: JSONValue = .object(["handle": .string(handle)])
    body.set("displayName", displayName.map(JSONValue.string))
    let user: UserPayload = try await self.api(.put, "/v1/user/me/profile", space: space, body: body)
    await self.runner.stdout("handle @\(user.handle ?? handle) (\(user.id))\n")
  }

  mutating func userProfile() async throws {
    let space = try self.wallet.pinnedSpace()
    guard let principal = try await self.persona(space: space) else {
      throw CLIError(message: "this device holds no identity in this space; enroll one with: wuhu login < invite-link")
    }
    let output: UsersOutput = try await self.api(.get, "/v1/users", space: space)
    guard let user = output.users.first(where: { $0.id == principal }) else {
      throw CLIError(message: "this space does not list \(principal)")
    }
    await self.runner.stdout(
      "\(user.handle.map { "@\($0)" } ?? "-") \(user.id)\(user.displayName.map { " \($0)" } ?? "")\n",
    )
  }

  mutating func userList() async throws {
    let space = try self.wallet.pinnedSpace()
    let output: AccountListOutput = try await self.api(.get, "/v1/accounts", space: space)
    let text = output.accounts.map { account in
      "\(account.id) \(account.kind)\(account.admin ? " admin" : "")\(account.name.map { " \($0)" } ?? "")\n"
    }.joined()
    await self.runner.stdout(text)
  }

  mutating func userRemove(account: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let output: AccountRemoveOutput = try await self.api(.delete, "/v1/accounts/\(account)", space: space)
    await self.runner.stdout("removed \(account) keys \(output.keys) read-sessions \(output.readSessions)\n")
  }

  mutating func keyList(account: String?) async throws {
    let space = try self.wallet.pinnedSpace()
    let path = "/v1/keys" + (account.map { "?account=\($0)" } ?? "")
    let output: KeyListOutput = try await self.api(.get, path, space: space)
    let text = output.keys.map { key in
      "\(key.pubkey) \(key.account) \(key.capabilities.joined(separator: ","))\(key.expiresAt.map { " expires \(Int($0))" } ?? "")\n"
    }.joined()
    await self.runner.stdout(text)
  }

  mutating func keyRevoke(pubkey: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let body: JSONValue = .object(["pubkey": .string(pubkey)])
    let _: EmptyOutput = try await self.api(.delete, "/v1/key", space: space, body: body)
    await self.runner.stdout("revoked \(pubkey)\n")
  }
}
