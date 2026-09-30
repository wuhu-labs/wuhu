#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import JSONValue
import protocol MachineChannel.FrameTransport
import enum PinnedTLS.PinnedTLS
import SpaceClient
import SpaceContract

struct Executor {
  var runner: CommandRunner
  var wallet: Wallet
  // Set in a session's exec: every request carries its token instead of a
  // wallet assertion, and only its own space is reachable.
  var session: SessionCredential?
  private(set) var group: GroupSelection
  var groupsConfirmed: Set<String> = []

  init(runner: CommandRunner, wallet: inout Wallet, session: SessionCredential? = nil, group: GroupSelection = .none) {
    self.runner = runner
    self.wallet = wallet
    self.session = session
    self.group = group
    self.wallet.group = group.group
  }

  mutating func select(_ group: GroupSelection) {
    self.group = group
    self.wallet.group = group.group
  }

  mutating func run(_ command: Command) async throws -> Int32 {
    switch command {
    case .help:
      preconditionFailure("help is routed before the executor")
    case .login:
      try await self.login()
    case let .shareLogin(ttl):
      try await self.shareLogin(ttl: ttl)
    case let .machineAdd(name):
      try await self.machineAdd(name: name)
    case let .machineJoin(server, fingerprint, name):
      try await self.machineJoin(server: server, fingerprint: fingerprint, name: name)
    case .machineRun:
      try await self.machineRun()
    case .machineList:
      try await self.machineList()
    case let .machineName(machine, name):
      try await self.machineName(machine: machine, name: name)
    case let .machineRotate(id):
      try await self.machineRotate(id: id)
    case let .machineRevoke(id):
      try await self.machineRevoke(id: id)
    case let .machineMove(machine, group):
      try await self.machineMove(machine: machine, group: group)
    case .deviceList:
      try await self.deviceList()
    case let .deviceSet(id, name, machine):
      try await self.deviceSet(id: id, name: name, machine: machine)
    case let .secretSet(name):
      try await self.secretSet(name: name)
    case .secretList:
      try await self.secretList()
    case let .secretRemove(name):
      try await self.secretRemove(name: name)
    case let .exec(command):
      return try await self.exec(command)
    case .ps:
      try await self.ps()
    case let .kill(id):
      try await self.kill(id: id)
    case let .use(space, pin, group):
      try await self.use(space: space, pinRequested: pin, group: group)
    case let .trust(space):
      try await self.retrust(space: space)
    case let .untrust(space):
      try await self.untrust(space: space)
    case let .read(path, rev, lines):
      let route = try self.route(path)
      var input: JSONValue = ["path": .string(route.path)]
      input.set("rev", rev.map(JSONValue.integer))
      input.set("lines", lines.map(JSONValue.string))
      let output: ReadOutput = try await self.tool("read", input, space: route.space)
      if rev == nil {
        try self.wallet.record(token: output.token, space: route.space, path: route.path)
      }
      await self.runner.stdout(output.content)
    case let .write(path, body, force):
      let route = try self.route(path)
      let token = try await self.ifMatchForMutation(path: route.path, space: route.space, force: force)
      var input: JSONValue = ["path": .string(route.path), "content": .string(body)]
      input.set("ifMatch", token.map(JSONValue.string))
      let output: WriteOutput = try await self.tool("write", input, space: route.space)
      try self.wallet.record(token: output.token, space: route.space, path: route.path)
      await self.runner.stdout(revPrefix(output.rev) + "token \(output.token)\n")
    case let .transcribe(file, language):
      try await self.transcribe(file: file, language: language)
    case .transcriber:
      try await self.transcriber()
    case let .cat(path):
      let route = try self.route(path)
      let data = try await self.authenticated(route.space).fileBytes(route.path)
      await self.runner.stdoutBytes(Array(data))
    case let .put(path, force):
      guard !self.runner.stdinIsTerminal else {
        throw UsageError(message: "put: reads bytes from stdin; redirect them (wuhu put \(path) < file)")
      }
      let route = try self.route(path)
      let token = try await self.ifMatchForMutation(path: route.path, space: route.space, force: force)
      var data = Data()
      for await chunk in self.runner.stdinChunks() {
        data.append(contentsOf: chunk)
      }
      let output: WriteOutput = try await self.authenticated(route.space)
        .putFileBytes(route.path, data, ifMatch: token)
      try self.wallet.record(token: output.token, space: route.space, path: route.path)
      await self.runner.stdout(revPrefix(output.rev) + "token \(output.token)\n")
    case let .edit(path, old, new, force):
      let route = try self.route(path)
      let token = try await self.ifMatchForMutation(path: route.path, space: route.space, force: force)
      let edit: JSONValue = ["old": .string(old), "new": .string(new)]
      var input: JSONValue = ["path": .string(route.path), "edits": .array([edit])]
      input.set("ifMatch", token.map(JSONValue.string))
      let output: EditOutput = try await self.tool("edit", input, space: route.space)
      try self.wallet.record(token: output.token, space: route.space, path: route.path)
      await self.runner.stdout(revPrefix(output.rev) + "token \(output.token)\n")
    case let .remove(path, force):
      let route = try self.route(path)
      let token = force ? nil : try self.wallet.token(space: route.space, path: route.path)
      var input: JSONValue = ["path": .string(route.path)]
      input.set("ifMatch", token.map(JSONValue.string))
      // Machine rm returns {} — there is no revision on a raw box.
      let output: OptionalRevision = try await self.tool("rm", input, space: route.space)
      try self.wallet.removeToken(space: route.space, path: route.path)
      await self.runner.stdout(output.rev.map { "rev \($0)\n" } ?? "")
    case let .move(from, to, replace):
      let route = try self.route([from, to])
      var input: JSONValue = ["from": .string(route.paths[0]), "to": .string(route.paths[1])]
      if replace { input.set("replace", .bool(true)) }
      let output: MoveOutput = try await self.tool("mv", input, space: route.space)
      try self.wallet.moveTokens(space: route.space, from: route.paths[0], to: route.paths[1])
      var text = output.rev.map { "rev \($0)\n" } ?? ""
      for path in output.dangling {
        text += "dangling \(path)\n"
      }
      await self.runner.stdout(text)
    case let .list(path, rev):
      let route = try self.route(path)
      var input: JSONValue = ["path": .string(route.path)]
      input.set("rev", rev.map(JSONValue.integer))
      let output: ListOutput = try await self.tool("ls", input, space: route.space)
      await self.runner.stdout(formatList(output))
    case let .stat(path):
      let route = try self.route(path)
      let input: JSONValue = ["path": .string(route.path)]
      let entry: Entry = try await self.tool("stat", input, space: route.space)
      try self.wallet.record(token: entry.token, space: route.space, path: route.path)
      await self.runner.stdout(formatStat(entry) + "\n")
    case let .grep(pattern, path, matchLimit, entryLimit, step):
      let route = try self.routeOptional(path)
      var input: JSONValue = ["pattern": .string(pattern)]
      input.set("path", route.path.map(JSONValue.string))
      input.set("matchLimit", matchLimit.map(JSONValue.integer))
      input.set("entryLimit", entryLimit.map(JSONValue.integer))
      input.set("step", step.map(JSONValue.string))
      let output: GrepOutput = try await self.tool("grep", input, space: route.space)
      await self.runner.stdout(formatGrep(output))
    case let .find(glob, path, matchLimit, entryLimit, step):
      let route = try self.routeOptional(path)
      var input: JSONValue = ["glob": .string(glob)]
      input.set("path", route.path.map(JSONValue.string))
      input.set("matchLimit", matchLimit.map(JSONValue.integer))
      input.set("entryLimit", entryLimit.map(JSONValue.integer))
      input.set("step", step.map(JSONValue.string))
      let output: FindOutput = try await self.tool("find", input, space: route.space)
      var text = output.paths.map { $0 + "\n" }.joined()
      if let cursor = output.cursor {
        text += "cursor \(cursor)\n"
      }
      await self.runner.stdout(text)
    case let .history(path):
      let route = try self.route(path)
      let input: JSONValue = ["path": .string(route.path)]
      let output: HistoryOutput = try await self.tool("history", input, space: route.space)
      await self.runner.stdout(formatHistory(output))
    case let .checkout(path, rev):
      let route = try self.route(path)
      let input: JSONValue = ["path": .string(route.path), "rev": .integer(rev)]
      let output: CheckoutOutput = try await self.tool("checkout", input, space: route.space)
      try self.wallet.record(token: output.token, space: route.space, path: route.path)
      await self.runner.stdout("rev \(output.rev) token \(output.token)\n")
    case let .query(sql):
      let space = try self.wallet.pinnedSpace()
      let input: JSONValue = ["sql": .string(sql)]
      let output: QueryOutput = try await self.tool("query", input, space: space)
      await self.runner.stdout(formatQuery(output))
    case let .tableCreate(path, header):
      let route = try self.route(path)
      let input: JSONValue = ["path": .string(route.path), "header": header]
      let output: RevisionOutput = try await self.tool("table.create", input, space: route.space)
      await self.runner.stdout("rev \(output.rev)\n")
    case let .tableAlter(path, header):
      let route = try self.route(path)
      let input: JSONValue = ["path": .string(route.path), "header": header]
      let output: RevisionOutput = try await self.tool("table.alter", input, space: route.space)
      await self.runner.stdout("rev \(output.rev)\n")
    case let .tableMutate(path, ops):
      let route = try self.route(path)
      let input: JSONValue = ["path": .string(route.path), "ops": ops]
      let output: RevisionOutput = try await self.tool("table.mutate", input, space: route.space)
      await self.runner.stdout("rev \(output.rev)\n")
    case let .new(template, container):
      let paths = [template] + (container.map { [$0] } ?? [])
      let route = try self.route(paths)
      var input: JSONValue = ["template": .string(route.paths[0])]
      input.set("in", route.paths.dropFirst().first.map(JSONValue.string))
      let output: NewOutput = try await self.tool("new", input, space: route.space)
      await self.runner.stdout(output.path + "\n")
    case let .observe(command):
      let space = try self.wallet.pinnedSpace()
      try await self.observe(command, space: space)
    case .serve:
      preconditionFailure("serve is routed before the executor")
    case .user:
      preconditionFailure("user is routed before the executor")
    case .userList:
      try await self.userList()
    case let .userHandle(handle, displayName):
      try await self.userHandle(handle: handle, displayName: displayName)
    case .userProfile:
      try await self.userProfile()
    case let .userRemove(account):
      try await self.userRemove(account: account)
    case let .keyList(account):
      try await self.keyList(account: account)
    case let .keyRevoke(pubkey):
      try await self.keyRevoke(pubkey: pubkey)
    case .upgrade:
      preconditionFailure("upgrade is routed before the executor")
    case .skillExport:
      try await self.skillExport()
    case .modelsUpdate:
      try await self.modelsUpdate()
    case let .usage(json):
      try await self.usage(json: json)
    case let .toolRoster(executor, json):
      try await self.toolRoster(executor: executor, json: json)
    case let .authSet(provider):
      try await self.authSet(provider: provider)
    case .authList:
      try await self.authList()
    case let .authRemove(provider):
      try await self.authRemove(provider: provider)
    case let .authLogin(provider):
      try await self.authLogin(provider: provider)
    case let .authLogout(provider):
      try await self.authLogout(provider: provider)
    case let .send(command):
      return try await self.send(command)
    case .inbox:
      try await self.inbox()
    case let .sessionCreate(command):
      try await self.sessionCreate(command)
    case let .sessionRequest(id, message, deadline):
      try await self.sessionRequest(id: id, message: message, deadline: deadline)
    case let .sessionAction(verb, id, force):
      try await self.sessionAction(verb, id: id, force: force)
    case let .sessionCompact(id, instructions):
      try await self.sessionCompact(id: id, instructions: instructions)
    case let .sessionRename(id, title):
      try await self.sessionRename(id: id, title: title)
    case let .sessionTags(id, tags):
      try await self.sessionTags(id: id, tags: tags)
    case let .sessionRestart(command):
      try await self.sessionRestart(command)
    case let .sessionLog(id, view):
      try await self.sessionLog(id: id, view: view)
    case let .sessionEntry(session, ref):
      try await self.sessionEntry(id: session, ref: ref)
    case .sessionList:
      try await self.sessionList()
    case .groupList:
      try await self.groupList()
    case let .groupUse(group):
      try await self.groupUse(group)
    case .groupCurrent:
      try await self.groupCurrent()
    case let .groupSet(id, spaceLayer):
      try await self.groupSet(id, spaceLayer: spaceLayer)
    }
    return 0
  }

  var trust: ServerTrust {
    get throws {
      try ServerTrust(environment: self.runner.environment)
    }
  }

  struct ServerEndpoint {
    var key: String
    var host: String
    var port: Int
    var secure: Bool
  }

  func endpoint(space: String) throws -> ServerEndpoint {
    guard let url = URL(string: self.client(space).base),
          let key = ServerTrust.hostKey(url: url),
          let host = url.host
    else {
      throw UsageError(message: "malformed server address: \(space)")
    }
    return ServerEndpoint(key: key, host: host, port: url.port ?? 443, secure: SpaceTransport.isSecure(url: url))
  }

  private mutating func use(space: String, pinRequested: Bool, group: String?) async throws {
    let trustLine = try await self.establishTrust(space: space, pinRequested: pinRequested)
    try await self.adoptAdvertisedIdentity(space: space)
    if let group {
      guard isValidGroupID(group) else {
        throw UsageError(message: "use: \(group) is not a group id: lowercase letters, digits and inner hyphens")
      }
      try await self.requireGroup(group, space: space)
    }
    // Re-pinning the same server keeps its group; an invalid one is dropped,
    // since use is how a broken config gets repaired.
    var kept: String?
    if group == nil, let configured = self.wallet.configuredGroup {
      let pinned = try? self.wallet.pinnedSpace()
      if !isValidGroupID(configured) {
        await self.runner.stderr("note: cleared the group \(configured): not a group id\n")
      } else if let pinned, !sameServer(pinned, space) {
        await self.runner.stderr("note: cleared the group \(configured): it belongs to \(pinned)\n")
      } else {
        kept = configured
      }
    }
    let recorded = group ?? kept
    let wallet = try self.wallet.pin(space, group: recorded)
    self.select(try GroupSelection.resolve(flag: nil, environment: self.runner.environment, config: recorded))
    let identity = try await self.persona(space: space)
    await self.runner.stdout(
      "pinned \(space) -> \(wallet.path)" + (recorded.map { " in group \($0)" } ?? "") + (identity.map { " as \($0)" } ?? "") + "\n",
    )
    if let trustLine {
      await self.runner.stdout(trustLine)
    }
  }

  // Discovery must not require a bearer: pinning a second address is exactly
  // the state where this host key has no identity mapping yet, so no
  // assertion can be minted through it. A server too old to advertise its
  // space id degrades to the pre-discovery behavior.
  private mutating func adoptAdvertisedIdentity(space: String) async throws {
    let endpoint = try self.endpoint(space: space)
    guard endpoint.secure else { return }
    let info: ServerInfo
    do {
      info = try await self.client(space).api(.get, "/v1/server")
    } catch {
      return
    }
    guard let advertised = info.space, isValidSpaceIdentity(advertised) else { return }
    let identities = try SpaceIdentityStore(environment: self.runner.environment)
    if let recorded = try identities.identity(forHost: endpoint.key), recorded != advertised {
      throw SpaceIdentityMismatch(host: endpoint.key, recorded: recorded, advertised: advertised)
    }
    try identities.record(advertised, forHost: endpoint.key)
  }

  private func establishTrust(space: String, pinRequested: Bool) async throws -> String? {
    let endpoint = try self.endpoint(space: space)
    guard endpoint.secure else {
      guard !pinRequested else {
        throw UsageError(message: "--pin requires an https server")
      }
      return nil
    }
    @Dependency(ServerTrustProbe.self) var probe
    let trust = try self.trust
    if pinRequested {
      let observed = try await probe.observeLeaf(endpoint.host, endpoint.port)
      let fingerprint = try PinnedTLS.fingerprint(certificateDERBase64: observed)
      try trust.record(fingerprint, forHost: endpoint.key)
      return "pinned server certificate \(fingerprint)\n"
    }
    if let pin = try trust.pin(forHost: endpoint.key) {
      return "server certificate \(pin) (pinned)\n"
    }
    do {
      try await probe.validateSystem(endpoint.host, endpoint.port)
      return "system trust OK\n"
    } catch {
      throw UntrustedServer(host: endpoint.key, cause: String(describing: error))
    }
  }

  private func retrust(space: String) async throws {
    let endpoint = try self.endpoint(space: space)
    let trust = try self.trust
    guard endpoint.secure, try trust.pin(forHost: endpoint.key) != nil else {
      throw CLIError(message: """
      no certificate pinned for \(endpoint.key); system trust is in effect
      to pin its certificate (trust on first use), run:
        wuhu use \(space) --pin
      """)
    }
    @Dependency(ServerTrustProbe.self) var probe
    let observed = try await probe.observeLeaf(endpoint.host, endpoint.port)
    let fingerprint = try PinnedTLS.fingerprint(certificateDERBase64: observed)
    try trust.record(fingerprint, forHost: endpoint.key)
    await self.runner.stdout("server certificate \(fingerprint)\n")
  }

  private func untrust(space: String) async throws {
    let endpoint = try self.endpoint(space: space)
    let trust = try self.trust
    guard try trust.pin(forHost: endpoint.key) != nil else {
      await self.runner.stdout("no trust record for \(endpoint.key)\n")
      return
    }
    try trust.removePin(forHost: endpoint.key)
    await self.runner.stdout("forgot \(endpoint.key)\n")
  }

  func client(_ space: String, group: String? = nil) -> SpaceClient {
    SpaceClient(
      space: space,
      fetch: self.runner.fetch,
      observeFetch: self.runner.observeFetch,
      dial: self.runner.dial,
      group: group,
    )
  }

  private mutating func route(_ path: String) throws -> (space: String, path: String) {
    let routed = try routePath(path)
    let space = try routed.spaceOverride.map(self.scoped) ?? self.wallet.pinnedSpace()
    return (space, routed.path)
  }

  private mutating func routeOptional(_ path: String?) throws -> (space: String, path: String?) {
    guard let path else {
      return (try self.wallet.pinnedSpace(), nil)
    }
    let routed = try self.route(path)
    return (routed.space, routed.path)
  }

  private mutating func route(_ paths: [String]) throws -> (space: String, paths: [String]) {
    let routed = try paths.map(routePath)
    let spaces = Set(routed.compactMap(\.spaceOverride))
    guard spaces.count <= 1 else {
      throw UsageError(message: "multiple spaces in one command are not supported")
    }
    let space = try spaces.first.map(self.scoped) ?? self.wallet.pinnedSpace()
    return (space, routed.map(\.path))
  }

  private mutating func ifMatchForMutation(path: String, space: String, force: Bool) async throws -> String? {
    if force { return nil }
    if let token = try self.wallet.token(space: space, path: path) {
      return token
    }

    let input: JSONValue = ["path": .string(path)]
    do {
      let _: Entry = try await self.tool("stat", input, space: space)
      throw CLIError(message: "refusing to overwrite \(path): read it first, or pass --force")
    } catch let error as SpaceClient.ToolFailure where error.error.code == .notFound {
      return nil
    }
  }

  private mutating func tool<Output: Decodable>(
    _ name: String,
    _ input: JSONValue,
    space: String,
  ) async throws -> Output {
    try await self.authenticated(space).tool(name, input)
  }
}

struct OptionalRevision: Decodable {
  let rev: Int?
}

extension JSONValue {
  mutating func set(_ key: String, _ value: JSONValue?) {
    guard let value else { return }
    guard case var .object(object) = self else {
      preconditionFailure("JSONValue.set requires an object")
    }
    object[key] = value
    self = .object(object)
  }
}

private func revPrefix(_ rev: Int?) -> String {
  rev.map { "rev \($0) " } ?? ""
}
