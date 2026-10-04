#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue
import struct SpaceClient.ObserveRequest
import SpaceContract

extension Command {
  static func parse(_ arguments: [String]) throws -> Self {
    var parser = ArgumentCursor(arguments)
    guard let verb = parser.pop() else {
      throw UsageError(message: Self.usage)
    }
    if verb == "--help" || verb == "-h" {
      try parser.finish(verb: "help")
      return .help(Self.usage)
    }
    // exec owns everything after `--` verbatim, so its arguments never pass
    // through the generic help scan or the `--`-skipping cursor.
    if verb == "exec" {
      return try parseExec(parser.remaining)
    }
    if parser.hasHelp {
      return .help(Self.help(for: verb, parser: parser))
    }

    switch verb {
    case "use":
      let pin = parser.flag("--pin")
      let group = try parser.option("--group", verb: verb)
      let host = try parser.required("host:port", verb: verb)
      try parser.finish(verb: verb)
      return .use(host, pin: pin, group: group)
    case "trust":
      let host = try parser.required("host:port", verb: verb)
      try parser.finish(verb: verb)
      return .trust(host)
    case "untrust":
      let host = try parser.required("host:port", verb: verb)
      try parser.finish(verb: verb)
      return .untrust(host)
    case "upgrade":
      let laneText = try parser.option("--lane", verb: verb)
      let check = parser.flag("--check")
      let rollback = parser.flag("--rollback")
      try parser.finish(verb: verb)
      let lane = try laneText.map { text in
        guard let lane = ReleaseLane(rawValue: text) else {
          throw UsageError(message: "upgrade: --lane must be dev, beta, or release")
        }
        return lane
      }
      if rollback, check || lane != nil {
        throw UsageError(message: "upgrade: --rollback stands alone")
      }
      return .upgrade(UpgradeCommand(check: check, rollback: rollback, lane: lane))
    case "read":
      let rev = try parser.intOption("--rev", verb: verb)
      let lines = try parser.option("--lines", verb: verb)
      let path = try parser.required("path", verb: verb)
      try parser.finish(verb: verb)
      return .read(path: path, rev: rev, lines: lines)
    case "write":
      let force = parser.flag("--force")
      let body = try parser.option("--body", verb: verb)
      let path = try parser.required("path", verb: verb)
      try parser.finish(verb: verb)
      guard let body else {
        throw UsageError(message: "write: --body <text> is required; to write bytes from stdin use: wuhu put \(path)")
      }
      return .write(path: path, body: body, force: force)
    case "cat":
      let path = try parser.required("path", verb: verb)
      try parser.finish(verb: verb)
      return .cat(path: path)
    case "web-search":
      let provider = try parser.option("--provider", verb: verb)
      let countText = try parser.option("--count", verb: verb)
      let count = countText.flatMap(Int.init)
      if countText != nil, count == nil { throw UsageError(message: "web-search: --count must be an integer") }
      let query = try parser.required("query", verb: verb)
      try parser.finish(verb: verb)
      return .webSearch(query: query, provider: provider, count: count)
    case "image":
      let provider = try parser.option("--provider", verb: verb)
      let model = try parser.option("--model", verb: verb)
      let quality = try parser.option("--quality", verb: verb)
      let size = try parser.option("--size", verb: verb)
      let destination = try parser.option("--destination", verb: verb)
      var images: [String] = []
      while let path = try parser.option("--image", verb: verb) { images.append(path) }
      let prompt = try parser.required("prompt", verb: verb)
      try parser.finish(verb: verb)
      guard let destination else { throw UsageError(message: "image: --destination <local-png-path> is required") }
      return .image(prompt: prompt, images: images, destination: destination, provider: provider, model: model, quality: quality, size: size)
    case "transcribe":
      let language = try parser.option("--language", verb: verb)
      let provider = try parser.option("--provider", verb: verb)
      let model = try parser.option("--model", verb: verb)
      let timestamps = try parser.option("--timestamps", verb: verb)
      let diarize = parser.flag("--diarize")
      let json = parser.flag("--json")
      guard let file = parser.pop() else {
        try parser.finish(verb: verb)
        return .transcriber
      }
      try parser.finish(verb: verb)
      return .transcribe(file: file, language: language, provider: provider, model: model, timestamps: timestamps, diarize: diarize, json: json)
    case "put":
      let force = parser.flag("--force")
      let path = try parser.required("path", verb: verb)
      try parser.finish(verb: verb)
      return .put(path: path, force: force)
    case "edit":
      let force = parser.flag("--force")
      let path = try parser.required("path", verb: verb)
      let old = try parser.required("old", verb: verb)
      let new = try parser.required("new", verb: verb)
      try parser.finish(verb: verb)
      return .edit(path: path, old: old, new: new, force: force)
    case "rm":
      let force = parser.flag("--force")
      let path = try parser.required("path", verb: verb)
      try parser.finish(verb: verb)
      return .remove(path: path, force: force)
    case "mv":
      let replace = parser.flag("--replace")
      let from = try parser.required("from", verb: verb)
      let to = try parser.required("to", verb: verb)
      try parser.finish(verb: verb)
      return .move(from: from, to: to, replace: replace)
    case "ls":
      let rev = try parser.intOption("--rev", verb: verb)
      let path = parser.pop() ?? "/"
      try parser.finish(verb: verb)
      return .list(path: path, rev: rev)
    case "stat":
      let path = try parser.required("path", verb: verb)
      try parser.finish(verb: verb)
      return .stat(path: path)
    case "grep":
      let matchLimit = try parser.intOption("--match-limit", verb: verb)
      let entryLimit = try parser.intOption("--entry-limit", verb: verb)
      let step = try parser.option("--step", verb: verb)
      let pattern = try parser.required("pattern", verb: verb)
      let path = parser.pop()
      try parser.finish(verb: verb)
      return .grep(pattern: pattern, path: path, matchLimit: matchLimit, entryLimit: entryLimit, step: step)
    case "find":
      let matchLimit = try parser.intOption("--match-limit", verb: verb)
      let entryLimit = try parser.intOption("--entry-limit", verb: verb)
      let step = try parser.option("--step", verb: verb)
      let glob = try parser.required("glob", verb: verb)
      let path = parser.pop()
      try parser.finish(verb: verb)
      return .find(glob: glob, path: path, matchLimit: matchLimit, entryLimit: entryLimit, step: step)
    case "history":
      let path = try parser.required("path", verb: verb)
      try parser.finish(verb: verb)
      return .history(path: path)
    case "checkout":
      let path = try parser.required("path", verb: verb)
      let rev = try parser.requiredInt("rev", verb: verb)
      try parser.finish(verb: verb)
      return .checkout(path: path, rev: rev)
    case "query":
      let sql = try parser.required("sql", verb: verb)
      try parser.finish(verb: verb)
      return .query(sql: sql)
    case "table":
      return try parseTable(&parser)
    case "new":
      let template = try parser.required("template", verb: verb)
      let container = parser.pop()
      try parser.finish(verb: verb)
      return .new(template: template, in: container)
    case "observe":
      return try parseObserve(&parser)
    case "login":
      // A stray argument here is almost certainly the invite link; the generic
      // finish echoes it, which would leak the token into logs and transcripts.
      guard parser.isFinished else {
        throw UsageError(message: "login: takes no arguments; the invite link is read from stdin (wuhu login < invite-link)")
      }
      return .login
    case "share-login":
      let ttl = try parser.intOption("--ttl", verb: verb)
      if let ttl, ttl <= 0 || ttl > ShareLogin.maximumTTLSeconds {
        throw UsageError(message: "share-login: --ttl must be 1...\(ShareLogin.maximumTTLSeconds) seconds")
      }
      try parser.finish(verb: verb)
      return .shareLogin(ttl: ttl)
    case "machine":
      return try parseMachine(&parser)
    case "device":
      return try parseDevice(&parser)
    case "secret":
      return try parseSecret(&parser)
    case "group":
      return try parseGroup(&parser)
    case "user":
      return try parseUser(&parser)
    case "key":
      return try parseKey(&parser)
    case "skill":
      guard let subcommand = parser.pop() else {
        throw UsageError(message: "skill: missing <export>")
      }
      guard subcommand == "export" else {
        throw UsageError(message: "skill: unknown subcommand \(subcommand)")
      }
      try parser.finish(verb: "skill export")
      return .skillExport
    case "models":
      guard let subcommand = parser.pop() else {
        throw UsageError(message: "models: missing <update>")
      }
      guard subcommand == "update" else {
        throw UsageError(message: "models: unknown subcommand \(subcommand)")
      }
      try parser.finish(verb: "models update")
      return .modelsUpdate
    case "usage":
      let json = parser.flag("--json")
      try parser.finish(verb: verb)
      return .usage(json: json)
    case "tool-roster":
      let raw = try parser.option("--executor", verb: verb)
      let json = parser.flag("--json")
      try parser.finish(verb: verb)
      let executor = try raw.map { text in
        guard let executor = SessionToolExecutor(rawValue: text) else {
          throw UsageError(
            message: "tool-roster: --executor is one of: "
              + SessionToolExecutor.allCases.map(\.rawValue).joined(separator: ", "),
          )
        }
        return executor
      }
      return .toolRoster(executor: executor, json: json)
    case "auth":
      return try parseAuth(&parser)
    case "send":
      return try parseSend(&parser)
    case "inbox":
      try parser.finish(verb: verb)
      return .inbox
    case "session":
      return try parseSession(&parser)
    case "ps":
      try parser.finish(verb: verb)
      return .ps
    case "kill":
      let id = try parser.required("exec-id", verb: verb)
      try parser.finish(verb: verb)
      return .kill(id: id)
    case "serve":
      let host = try parser.option("--host", verb: verb) ?? "127.0.0.1"
      let port = try parser.intOption("--port", verb: verb) ?? 5530
      let dev = parser.flag("--dev")
      let publicRead = parser.flag("--public-read")
      let devImport = try parser.option("--dev-import", verb: verb)
      let devExport = try parser.option("--dev-export", verb: verb)
      let cert = try parser.option("--cert", verb: verb)
      let key = try parser.option("--key", verb: verb)
      let webApp = try parser.option("--web-app", verb: verb)
      var ignored: [String] = []
      for name in ["--web-port", "--web-origin"] {
        if try parser.option(name, verb: verb) != nil { ignored.append(name) }
      }
      if (cert == nil) != (key == nil) {
        throw UsageError(message: "serve requires --cert and --key together")
      }
      let groupCert = try parser.option("--group-certificate", verb: verb)
      let groupKey = try parser.option("--group-private-key", verb: verb)
      if (groupCert == nil) != (groupKey == nil) {
        throw UsageError(message: "serve requires --group-certificate and --group-private-key together")
      }
      var origin = try parser.option("--origin", verb: verb)
      if let raw = origin {
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
        else {
          throw UsageError(message: "serve: --origin must be an https:// origin (scheme + host [+ port], no path)")
        }
        if let host = url.host, isIPLiteral(host) {
          throw UsageError(message: """
          serve: --origin must be a name, not an IP address: group content is served on <group>.<host>. \
          Use an sslip.io name for the address, such as https://192-168-1-5.sslip.io:5530
          """)
        }
        origin = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
      }
      if groupCert != nil, origin == nil {
        throw UsageError(message: "serve: --group-certificate needs --origin, whose host names the group hosts")
      }
      if groupCert != nil, cert == nil {
        throw UsageError(message: "serve: --group-certificate needs --cert/--key: invites pin the generated certificate, which must serve every host")
      }
      let folder = try parser.required("folder", verb: verb)
      try parser.finish(verb: verb)
      return .serve(ServeCommand(
        folder: folder,
        host: host,
        port: port,
        origin: origin,
        dev: dev,
        publicRead: publicRead,
        devImport: devImport,
        devExport: devExport,
        certificate: cert,
        privateKey: key,
        groupCertificate: groupCert,
        groupPrivateKey: groupKey,
        webApp: webApp,
        ignoredOptions: ignored,
      ))
    default:
      throw UsageError(message: Self.usage)
    }
  }

  private static func help(for verb: String, parser: ArgumentCursor) -> String {
    if ["table", "machine", "device", "secret", "group", "user", "key", "skill", "models", "session", "auth"].contains(verb),
       let subcommand = parser.remaining.first(where: { $0 != "--help" && $0 != "-h" })
    {
      return Self.verbHelp["\(verb) \(subcommand)"] ?? Self.verbHelp[verb]!
    }
    return Self.verbHelp[verb] ?? Self.usage
  }

  private static func parseAuth(_ parser: inout ArgumentCursor) throws -> Self {
    guard let subcommand = parser.pop() else {
      throw UsageError(message: "auth: missing <set|list|remove|login|logout>")
    }
    switch subcommand {
    case "set":
      let provider = try parser.required("provider", verb: "auth set")
      try parser.finish(verb: "auth set")
      return .authSet(provider: provider)
    case "list":
      try parser.finish(verb: "auth list")
      return .authList
    case "remove":
      let provider = try parser.required("provider", verb: "auth remove")
      try parser.finish(verb: "auth remove")
      return .authRemove(provider: provider)
    case "login":
      let provider = try parser.required("provider", verb: "auth login")
      try parser.finish(verb: "auth login")
      return .authLogin(provider: provider)
    case "logout":
      let provider = try parser.required("provider", verb: "auth logout")
      try parser.finish(verb: "auth logout")
      return .authLogout(provider: provider)
    default:
      throw UsageError(message: "auth: unknown subcommand \(subcommand)")
    }
  }

  private static func parseSend(_ parser: inout ArgumentCursor) throws -> Self {
    let wait = parser.flag("--wait")
    let timeout = try parser.doubleOption("--timeout", verb: "send")
    var attachments: [String] = []
    while let attachment = try parser.option("--attach", verb: "send") {
      attachments.append(attachment)
    }
    let session = try parser.required("session-id", verb: "send")
    let text = try parser.required("message", verb: "send")
    try parser.finish(verb: "send")
    if timeout != nil, !wait {
      throw UsageError(message: "send: --timeout requires --wait")
    }
    return .send(SendCommand(session: session, text: text, wait: wait, timeout: timeout, attachments: attachments))
  }

  private static func parseGroup(_ parser: inout ArgumentCursor) throws -> Self {
    guard let subcommand = parser.pop() else {
      throw UsageError(message: "group: missing <list|use|current|set>")
    }
    switch subcommand {
    case "list":
      try parser.finish(verb: "group list")
      return .groupList
    case "use":
      let clear = parser.flag("--clear")
      let id = parser.pop()
      try parser.finish(verb: "group use")
      switch (id, clear) {
      case let (id?, false): return .groupUse(id)
      case (nil, true): return .groupUse(nil)
      default: throw UsageError(message: "group use: pass <id> or --clear")
      }
    case "current":
      try parser.finish(verb: "group current")
      return .groupCurrent
    case "set":
      let layer = try parser.option("--space-layer", verb: "group set")
      let id = try parser.required("id", verb: "group set")
      try parser.finish(verb: "group set")
      switch layer {
      case "on": return .groupSet(id: id, spaceLayer: true)
      case "off": return .groupSet(id: id, spaceLayer: false)
      default: throw UsageError(message: "group set: pass --space-layer on|off")
      }
    default:
      throw UsageError(message: "group: unknown subcommand \(subcommand)")
    }
  }

  private static func parseSession(_ parser: inout ArgumentCursor) throws -> Self {
    guard let subcommand = parser.pop() else {
      throw UsageError(message: "session: missing <create|request|restart|rename|tags|interrupt|resume|compact|archive|unarchive|log|entry|list>")
    }
    switch subcommand {
    case "create":
      let topLevel = parser.flag("--top-level")
      let kind = try parser.option("--kind", verb: "session create")
      let provider = try parser.option("--provider", verb: "session create")
      let model = try parser.option("--model", verb: "session create")
      let effort = try parser.option("--effort", verb: "session create")
      let template = try parser.option("--template", verb: "session create")
      let homeGroup = try parser.option("--home-group", verb: "session create")
      var tags: [String] = []
      while let tag = try parser.option("--tag", verb: "session create") {
        tags.append(tag)
      }
      let title = try parser.required("title", verb: "session create")
      try parser.finish(verb: "session create")
      if let kind, kind != "agent", kind != "task" {
        throw UsageError(message: "session create: --kind is agent or task")
      }
      return .sessionCreate(SessionCreateCommand(
        kind: kind, title: title, provider: provider, model: model,
        effort: effort, tags: tags, template: template, topLevel: topLevel, homeGroup: homeGroup,
      ))
    case "request":
      let deadline = try parser.doubleOption("--deadline", verb: "session request")
      let id = try parser.required("session-id", verb: "session request")
      let message = try parser.required("message", verb: "session request")
      try parser.finish(verb: "session request")
      return .sessionRequest(id: id, message: message, deadline: deadline)
    case "restart":
      let provider = try parser.option("--provider", verb: "session restart")
      let model = try parser.option("--model", verb: "session restart")
      let effort = try parser.option("--effort", verb: "session restart")
      let message = try parser.option("--message", verb: "session restart")
      let id = try parser.required("session-id", verb: "session restart")
      try parser.finish(verb: "session restart")
      return .sessionRestart(SessionRestartCommand(
        id: id, provider: provider, model: model, effort: effort, message: message,
      ))
    case "rename":
      let id = try parser.required("session-id", verb: "session rename")
      let title = try parser.required("title", verb: "session rename")
      try parser.finish(verb: "session rename")
      return .sessionRename(id: id, title: title)
    case "tags":
      let id = try parser.required("session-id", verb: "session tags")
      var tags: [String] = []
      while let tag = parser.pop() {
        tags.append(tag)
      }
      return .sessionTags(id: id, tags: tags)
    case "compact":
      let instructions = try parser.option("--instructions", verb: "session compact")
      let id = try parser.required("session-id", verb: "session compact")
      try parser.finish(verb: "session compact")
      return .sessionCompact(id: id, instructions: instructions)
    case "interrupt", "resume", "archive", "unarchive":
      let force = subcommand == "archive" && parser.flag("--force")
      let id = try parser.required("session-id", verb: "session \(subcommand)")
      try parser.finish(verb: "session \(subcommand)")
      return .sessionAction(SessionActionVerb(rawValue: subcommand)!, id: id, force: force)
    case "log":
      let direct = parser.flag("--direct")
      let verbose = parser.flag("-v")
      let veryVerbose = parser.flag("-vv")
      let limit = try parser.intOption("--limit", verb: "session log")
      let before = try parser.option("--before", verb: "session log")
      let id = try parser.required("session-id", verb: "session log")
      try parser.finish(verb: "session log")
      guard direct || verbose || veryVerbose else {
        var conversationBefore: Int?
        if let before {
          guard let n = Int(before), n >= 0 else {
            throw UsageError(message: "session log: the conversation view pages by the [n] cursor; --before wants an integer (switch to --direct for refs)")
          }
          conversationBefore = n
        }
        return .sessionLog(id: id, view: .conversation(limit: limit, before: conversationBefore))
      }
      let level = veryVerbose ? 3 : verbose ? 2 : 1
      return .sessionLog(id: id, view: .direct(level: level, limit: limit, before: before))
    case "entry":
      let session = try parser.required("session-id", verb: "session entry")
      let ref = try parser.required("ref", verb: "session entry")
      try parser.finish(verb: "session entry")
      return .sessionEntry(session: session, ref: ref)
    case "list":
      try parser.finish(verb: "session list")
      return .sessionList
    default:
      throw UsageError(message: "session: unknown subcommand \(subcommand)")
    }
  }

  private static func parseDevice(_ parser: inout ArgumentCursor) throws -> Self {
    guard let subcommand = parser.pop() else {
      throw UsageError(message: "device: missing <list|set>")
    }
    switch subcommand {
    case "list":
      try parser.finish(verb: "device list")
      return .deviceList
    case "set":
      let id = try parser.required("device", verb: "device set")
      let name = try parser.option("--name", verb: "device set")
      let machine = try parser.option("--machine", verb: "device set")
      try parser.finish(verb: "device set")
      guard name != nil || machine != nil else {
        throw UsageError(message: "device set: nothing to change; pass --name, --machine, or both")
      }
      return .deviceSet(id: id, name: name, machine: machine)
    default:
      throw UsageError(message: "device: unknown subcommand \(subcommand)")
    }
  }

  private static func parseMachine(_ parser: inout ArgumentCursor) throws -> Self {
    guard let subcommand = parser.pop() else {
      throw UsageError(message: "machine: missing <add|join|run|list|name|rotate|revoke|move>")
    }
    switch subcommand {
    case "add":
      let name = try parser.option("--name", verb: "machine add")
      try parser.finish(verb: "machine add")
      return .machineAdd(name: name)
    case "join":
      let name = try parser.option("--name", verb: "machine join")
      let server = try parser.required("server-url", verb: "machine join")
      let fingerprint = parser.pop()
      // Any other argument here — including the token pasted as the server —
      // is almost certainly the join token; the generic errors echo it, and
      // dialing it as a host would leak it in a DNS query.
      guard !server.hasPrefix("jt_"), fingerprint.map(ServerTrust.isFingerprint) ?? true, parser.isFinished else {
        throw UsageError(message: """
        machine join: the token is read from stdin, never from arguments (wuhu machine join <server-url> [fingerprint] < token); \
        the only argument after <server-url> is a sha256:<64 lowercase hex> fingerprint
        """)
      }
      return .machineJoin(server: server, fingerprint: fingerprint, name: name)
    case "run":
      try parser.finish(verb: "machine run")
      return .machineRun
    case "list":
      try parser.finish(verb: "machine list")
      return .machineList
    case "name":
      let machine = try parser.required("machine", verb: "machine name")
      let name = try parser.required("name", verb: "machine name")
      try parser.finish(verb: "machine name")
      return .machineName(machine: machine, name: name)
    case "rotate":
      let id = try parser.required("machine", verb: "machine rotate")
      try parser.finish(verb: "machine rotate")
      return .machineRotate(id: id)
    case "revoke":
      let id = try parser.required("machine", verb: "machine revoke")
      try parser.finish(verb: "machine revoke")
      return .machineRevoke(id: id)
    case "move":
      let group = try parser.option("--group", verb: "machine move")
      let machine = try parser.required("machine", verb: "machine move")
      try parser.finish(verb: "machine move")
      guard let group else { throw UsageError(message: "machine move: --group <group> is required") }
      return .machineMove(machine: machine, group: group)
    default:
      throw UsageError(message: "machine: unknown subcommand \(subcommand)")
    }
  }

  private static func parseUser(_ parser: inout ArgumentCursor) throws -> Self {
    guard let subcommand = parser.pop() else {
      throw UsageError(message: "user: missing <add|reset|invite|list|remove|handle|profile>")
    }
    switch subcommand {
    case "add":
      let admin = parser.flag("--admin")
      guard let folder = try parser.option("--space", verb: "user add") else {
        throw UsageError(message: "user add: --space <folder> is required")
      }
      let name = try parser.option("--name", verb: "user add")
      try parser.finish(verb: "user add")
      return .user(.add(folder: folder, name: name, admin: admin))
    case "list":
      try parser.finish(verb: "user list")
      return .userList
    case "handle":
      let displayName = try parser.option("--display-name", verb: "user handle")
      let handle = try parser.required("handle", verb: "user handle")
      try parser.finish(verb: "user handle")
      return .userHandle(handle: handle, displayName: displayName)
    case "profile":
      try parser.finish(verb: "user profile")
      return .userProfile
    case "remove":
      let account = try parser.required("account-id", verb: "user remove")
      try parser.finish(verb: "user remove")
      return .userRemove(account: account)
    case "reset":
      guard let folder = try parser.option("--space", verb: "user reset") else {
        throw UsageError(message: "user reset: --space <folder> is required")
      }
      let account = try parser.required("account-id", verb: "user reset")
      try parser.finish(verb: "user reset")
      return .user(.reset(folder: folder, account: account))
    case "invite":
      guard let folder = try parser.option("--space", verb: "user invite") else {
        throw UsageError(message: "user invite: --space <folder> is required")
      }
      var server = try parser.option("--server", verb: "user invite")
      if let raw = server {
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
        else {
          throw UsageError(message: "user invite: --server must be an https:// origin (scheme + host [+ port], no path)")
        }
        server = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
      }
      let ttl = try parser.intOption("--ttl", verb: "user invite")
      if let ttl, ttl <= 0 {
        throw UsageError(message: "user invite: --ttl must be a positive number of seconds")
      }
      let account = try parser.required("account-id", verb: "user invite")
      try parser.finish(verb: "user invite")
      return .user(.invite(folder: folder, account: account, server: server, ttl: ttl))
    default:
      throw UsageError(message: "user: unknown subcommand \(subcommand)")
    }
  }

  private static func parseKey(_ parser: inout ArgumentCursor) throws -> Self {
    guard let subcommand = parser.pop() else {
      throw UsageError(message: "key: missing <list|revoke>")
    }
    switch subcommand {
    case "list":
      let account = try parser.option("--account", verb: "key list")
      try parser.finish(verb: "key list")
      return .keyList(account: account)
    case "revoke":
      let pubkey = try parser.required("pubkey", verb: "key revoke")
      try parser.finish(verb: "key revoke")
      return .keyRevoke(pubkey: pubkey)
    default:
      throw UsageError(message: "key: unknown subcommand \(subcommand)")
    }
  }

  private static func parseSecret(_ parser: inout ArgumentCursor) throws -> Self {
    switch parser.pop() {
    case "set":
      let name = try parser.required("name", verb: "secret set")
      try parser.finish(verb: "secret set")
      return .secretSet(name: name)
    case "list":
      try parser.finish(verb: "secret list")
      return .secretList
    case "remove":
      let name = try parser.required("name", verb: "secret remove")
      try parser.finish(verb: "secret remove")
      return .secretRemove(name: name)
    case let subcommand?:
      throw UsageError(message: "secret: unknown subcommand \(subcommand)")
    case nil:
      throw UsageError(message: "secret: missing <set|list|remove>")
    }
  }

  private static func parseExec(_ arguments: [String]) throws -> Self {
    var flags = arguments
    var command: [String] = []
    if let separator = flags.firstIndex(of: "--") {
      command = Array(flags[flags.index(after: separator)...])
      flags = Array(flags[..<separator])
    }
    if flags.contains("--help") || flags.contains("-h") {
      return .help(Self.verbHelp["exec"]!)
    }
    var cursor = ArgumentCursor(flags)
    guard let cwd = try cursor.option("--cwd", verb: "exec") else {
      throw UsageError(message: "exec: --cwd machines://<name-or-id>/<path> is required")
    }
    var secrets: [String: String] = [:]
    while let pair = try cursor.option("--secret", verb: "exec") {
      guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
        throw UsageError(message: "exec: --secret wants ENV=NAME, got \(pair)")
      }
      let env = String(pair[..<equals])
      let name = String(pair[pair.index(after: equals)...])
      guard !name.isEmpty else {
        throw UsageError(message: "exec: --secret wants ENV=NAME, got \(pair)")
      }
      guard secrets[env] == nil else {
        throw UsageError(message: "exec: duplicate --secret for \(env)")
      }
      secrets[env] = name
    }
    let window = try cursor.intOption("--window", verb: "exec")
    let maxOutput = try cursor.intOption("--max-output", verb: "exec")
    let timeout = try cursor.doubleOption("--timeout", verb: "exec")
    try cursor.finish(verb: "exec")
    guard !command.isEmpty else {
      throw UsageError(message: "exec: missing -- <command...>")
    }
    return .exec(ExecCommand(
      cwd: cwd,
      secrets: secrets,
      window: window,
      maxOutput: maxOutput,
      timeout: timeout,
      command: command,
    ))
  }

  private static func parseTable(_ parser: inout ArgumentCursor) throws -> Self {
    guard let subcommand = parser.pop() else {
      throw UsageError(message: "table: missing <create|alter|mutate>")
    }
    let path = try parser.required("path", verb: "table \(subcommand)")
    switch subcommand {
    case "create":
      let header = try contractArgument(TableHeader.self, parser.required("header-json", verb: "table create"), verb: "table create")
      try parser.finish(verb: "table create")
      return .tableCreate(path: path, header: header)
    case "alter":
      let header = try contractArgument(TableHeader.self, parser.required("header-json", verb: "table alter"), verb: "table alter")
      try parser.finish(verb: "table alter")
      return .tableAlter(path: path, header: header)
    case "mutate":
      let ops = try contractArgument([RowOp].self, parser.required("ops-json", verb: "table mutate"), verb: "table mutate")
      try parser.finish(verb: "table mutate")
      return .tableMutate(path: path, ops: ops)
    default:
      throw UsageError(message: "table: unknown subcommand \(subcommand)")
    }
  }

  private static func parseObserve(_ parser: inout ArgumentCursor) throws -> Self {
    let glob = try parser.option("--glob", verb: "observe")
    let sql = try parser.option("--sql", verb: "observe")
    let from = try parser.intOption("--from", verb: "observe")
    let throttleMs = try parser.intOption("--throttle-ms", verb: "observe")
    let once = parser.flag("--once")
    try parser.finish(verb: "observe")

    switch (glob, sql) {
    case let (pattern?, nil):
      return .observe(ObserveCommand(request: ObserveRequest(mode: .glob(pattern), from: from, throttleMs: throttleMs), once: once))
    case let (nil, query?):
      guard from == nil else { throw UsageError(message: "observe: --from applies only to --glob") }
      return .observe(ObserveCommand(request: ObserveRequest(mode: .sql(query), throttleMs: throttleMs), once: once))
    case (nil, nil):
      throw UsageError(message: "observe: pass --glob <pattern> or --sql <query>")
    case (_?, _?):
      throw UsageError(message: "observe: pass only one of --glob or --sql")
    }
  }

  private static func contractArgument<T: Decodable>(_ type: T.Type, _ text: String, verb: String) throws -> JSONValue {
    guard let value = JSONValue.parse(text) else {
      throw UsageError(message: "\(verb): invalid JSON")
    }
    do {
      _ = try JSONValueDecoder().decode(type, from: value)
      return value
    } catch {
      throw UsageError(message: "\(verb): JSON does not match contract")
    }
  }

  static let usage = """
  usage: wuhu [--group <id>] <verb> [--help] | wuhu --version

  verbs:
    use       pin this checkout to a space host:port
    login     enroll this device at a space from a one-time invite link
    share-login  mint a one-time login link for your account and show it as a QR
    trust     re-record a pinned server certificate after an expected change
    untrust   forget the trust record for a server
    upgrade   self-update from wuhu.ai into ~/.wuhu/bin
    read      print file text, clamped to a line range
    write     write --body text to a path
    cat       write a path's raw bytes to stdout
    put       write raw stdin bytes to a path
    transcribe  transcribe an audio file through the space's provider
    web-search search the public web through the space's provider
    image      generate or edit an image; create-only local output
    edit      replace one text span
    rm        remove a path
    mv        move a path
    ls        list directory entries
    stat      show labeled metadata for a path
    grep      search file contents
    find      find paths by glob
    history   show revision history
    checkout  restore a prior revision
    query     run a SELECT query
    table     create, alter, or mutate tables
    new       instantiate a template
    observe   stream glob or SQL observations
    serve <folder>  run the space server
    machine   add, join, run, list, name, rotate, revoke, or move machines
    device    list the phones, pads, macs and vision devices signed into this space, or annotate one
    user      accounts: offline recovery (add/reset/invite), live list/remove, and your own handle/profile
    key       list or revoke enrolled device keys in the pinned space
    secret    manage your group's secrets for run_script and execs (write-only)
    group     list the space's groups, or choose the one this wallet acts in
    exec      run a command on a machine (duplex, pipe-clean)
    ps        list live execs
    kill      kill an exec by id
    skill     install the bundled agent skills into coding agent homes
    models    sync the space models document from the published basis
    usage     print each provider's plan usage windows (codex, claude)
    tool-roster  print the tools a kernel or Claude Code session is given
    auth      manage the space's provider credentials (api keys, chatgpt login)
    send      post a message to a session (an agent's box; a task takes no messages from people)
    inbox     print notifications above your wallet cursor and advance it
    session   create, steer, and read sessions

  --group <id> acts in that group for one command (else WUHU_GROUP, else the
  wallet's group from wuhu group use; with none the server picks).

  run: wuhu <verb> --help
  """

  private static let exitCodes = """

  exit codes:
    0  success
    64 usage error
    1  runtime error
  """

  private static let verbHelp: [String: String] = [
    "use": """
    usage: wuhu use <host:port> [--pin] [--group <id>]

    pins the nearest walk-up .wuhu wallet to <host:port>; creates ./.wuhu when none exists.
    the server certificate must pass system trust (OS trust store, hostname
    included); nothing is recorded on success. when the system does not trust
    the server, --pin records its certificate fingerprint (trust on first use)
    in the user-level ~/.wuhu/trust.json, honored from every working folder;
    later connections verify the pin instead of the system trust store.
    --group records the group this wallet acts in (see wuhu group use); a pin
    without it records none, so the server picks.
    \(exitCodes)
    """,
    "trust": """
    usage: wuhu trust <host:port>

    replaces the pinned certificate for <host:port> with the one the server
    currently presents; applies only to servers pinned via wuhu use --pin
    (a CA-trusted server needs no pin). run this after an expected certificate
    change; a pin mismatch is otherwise a hard failure.
    \(exitCodes)
    """,
    "untrust": """
    usage: wuhu untrust <host:port>

    forgets the user-level trust record (~/.wuhu/trust.json) for <host:port>;
    the next connection falls back to system trust. exits 0 whether or not a
    record existed.
    \(exitCodes)
    """,
    "login": """
    usage: wuhu login < invite-link

    enrolls this device at the space behind a one-time invite link
    (https://host:port/_/enroll#token=jt_...&space=spc_...[&fp=sha256:...]). the
    link is read from stdin (one trailing line ending is stripped), never from
    arguments: its token enrolls whatever key the holder presents, and argv
    leaks via ps. generates the per-space ed25519 device key into
    ~/.wuhu/keys/<space-id>.key when this device has none yet (keys are never
    reused across spaces and never leave this machine), records the delivered
    certificate fingerprint into the user trust store when present (a link
    without one drops this host's pin once the server passes system trust, and
    enrolls through the pin when it does not), and presents the public key. the link dies at enrollment; a second use
    fails.
    \(exitCodes)
    """,
    "share-login": """
    usage: wuhu share-login [--ttl <seconds>]

    mints a one-time login link for this device's account in the pinned space
    and renders it as a terminal QR code plus a plain URL. scan it with the
    device to onboard; the link dies at first use or after --ttl seconds
    (default 600, at most 259200 — 3 days). requires this device to be
    enrolled (wuhu login).
    \(exitCodes)
    """,
    "upgrade": """
    usage: wuhu upgrade [--check] [--lane dev|beta|release] | wuhu upgrade --rollback

    updates the installed wuhu under ~/.wuhu/bin from https://wuhu.ai, which
    serves the lane pointer and the artifacts it names; no token, no account.
    every download is verified against the sha256 in that pointer.
    layout: ~/.wuhu/bin/<version>/wuhu, with ~/.wuhu/bin/wuhu a copy of the
    current version's binary, renamed into place so its path never changes
    (macOS privacy grants follow it); the last 3 versions are kept.
    the binary follows its own release lane; ordering is (train semver, lane
    counter) within a lane only. never touches PATH, shells, or dotfiles.
    flags:
      --check     print the newest release in the lane without installing
      --lane L    cross to another lane's latest release
      --rollback  put the previously current version back at ~/.wuhu/bin/wuhu
    \(exitCodes)
    """,
    "read": """
    usage: wuhu read <path> [--rev N] [--lines A-B]

    arguments:
      <path>       space path, another group's (wuhu://<group>.localspace/path),
                   or a space URL (https://host/path, wuhu://host/path)
    flags:
      --rev N      read a historical revision without recording an etag
      --lines A-B  read an inclusive 1-based line range
    \(exitCodes)
    """,
    "write": """
    usage: wuhu write <path> --body <text> [--force]

    writes <text> to <path> through the JSON tool wire, which carries UTF-8
    text only. for bytes — images, archives, anything binary — use wuhu put.
    flags:
      --body <text>  the content to write (required)
      --force        skip overwrite preflight and omit ifMatch
    \(exitCodes)
    """,
    "cat": """
    usage: wuhu cat <path>

    writes <path>'s raw bytes to stdout over the byte route (GET /v1/f<path>),
    unclamped and byte-exact. no line semantics, and no wallet token is
    recorded — pair it with wuhu put --force, or wuhu read for text.
    \(exitCodes)
    """,
    "web-search": """
    usage: wuhu web-search <query> [--provider <id>] [--count <1..20>]

    prints normalized JSON sources from the space capability resolver. Do not build
    a persistent search corpus or use Brave results to train/evaluate models.
    """,
    "image": """
    usage: wuhu image <prompt> --destination <local-png-path> [--image <local-png-path>]... [--provider <id>] [--model <id>] [--quality draft|standard|fine|ultra] [--size 1024x1024|1536x1024|1024x1536]

    generates a PNG, or edits when --image is present. Uploads private reference
    bytes internally and creates the local output exclusively; never overwrites.
    """,
    "transcribe": """
    usage: wuhu transcribe [<file>] [--language <code>] [--provider <id>] [--model <id>] [--timestamps words,segments] [--diarize] [--json]

    uploads <file> to the pinned space (POST /v1/transcribe) and prints the
    transcript. /capabilities.json selects the active provider; --provider overrides
    it explicitly. Only an unconfigured capability synthesizes Codex; broken
    configuration never falls back. Accepts WAV, MP3, M4A/MP4 and
    WebM with readable timing, up to 25 MiB/two hours. --json includes available
    timestamp/speaker metadata. With no <file> it prints the provider and
    model the space would use, or "no transcriber".
    \(exitCodes)
    """,
    "put": """
    usage: wuhu put <path> [--force]

    writes stdin's raw bytes to <path> over the byte route (PUT /v1/f<path>),
    byte-exact with no UTF-8 requirement. the server derives the served
    content type from the path extension. records the resulting token.
    flags:
      --force  skip overwrite preflight and omit ifMatch
    \(exitCodes)
    """,
    "edit": """
    usage: wuhu edit <path> <old> <new> [--force]

    replaces one text span using the server edit tool.
    flags:
      --force  omit ifMatch
    \(exitCodes)
    """,
    "rm": """
    usage: wuhu rm <path> [--force]

    removes <path> and clears its wallet token.
    flags:
      --force  omit ifMatch
    \(exitCodes)
    """,
    "mv": """
    usage: wuhu mv <from> <to> [--replace]

    moves a path and migrates wallet tokens under that path. an existing <to> refuses the move.
    flags:
      --replace  replace an existing file at <to> in the same revision
    \(exitCodes)
    """,
    "ls": """
    usage: wuhu ls [path] [--rev N]

    lists entries using compact d/-/t markers.
    flags:
      --rev N  list a historical revision
    \(exitCodes)
    """,
    "stat": """
    usage: wuhu stat <path>

    prints labeled kind, size, optional line count, token, and local ISO-8601 mtime.
    \(exitCodes)
    """,
    "grep": """
    usage: wuhu grep <pattern> [path] [--match-limit N] [--entry-limit N] [--step cursor]

    searches file contents.
    \(exitCodes)
    """,
    "find": """
    usage: wuhu find <glob> [path] [--match-limit N] [--entry-limit N] [--step cursor]

    finds paths matching <glob> under [path].
    \(exitCodes)
    """,
    "history": """
    usage: wuhu history <path>

    prints revision history for <path>.
    \(exitCodes)
    """,
    "checkout": """
    usage: wuhu checkout <path> <rev>

    restores <path> from <rev> and records the new live token.
    \(exitCodes)
    """,
    "query": """
    usage: wuhu query <sql>

    runs a SELECT query.
    \(exitCodes)
    """,
    "table": """
    usage: wuhu table <create|alter|mutate> ...

    subcommands:
      create <path> <header-json>
      alter  <path> <header-json>
      mutate <path> <ops-json>
    \(exitCodes)
    """,
    "table create": """
    usage: wuhu table create <path> <header-json>

    creates a table at <path>.
    \(exitCodes)
    """,
    "table alter": """
    usage: wuhu table alter <path> <header-json>

    replaces a table header.
    \(exitCodes)
    """,
    "table mutate": """
    usage: wuhu table mutate <path> <ops-json>

    applies row operations.
    \(exitCodes)
    """,
    "new": """
    usage: wuhu new <template> [in]

    instantiates a template, optionally under [in].
    \(exitCodes)
    """,
    "observe": """
    usage: wuhu observe (--glob <pattern> | --sql <query>) [--from REV] [--throttle-ms N] [--once]

    streams server-sent events, one JSON payload per line.
    flags:
      --glob <pattern>   observe mutation events matching a glob
      --sql <query>      observe query snapshots
      --from REV         glob: replay journal events with rev > REV before going live
      --throttle-ms N    throttle SQL snapshots on the server
      --once             glob: print the first event; sql: skip equal snapshot hashes, print first change
    \(exitCodes)
    """,
    "serve": """
    usage: wuhu serve <folder> [--host <address>] [--port N] [--origin <url>] [--dev] [--public-read] [--dev-import <folder>] [--dev-export <folder>] [--cert <pem> --key <pem>] [--group-certificate <pem> --group-private-key <pem>] [--web-app <dir>]

    runs the space server on one TLS port (--port, default 5530). Without
    --cert/--key a self-signed certificate is generated into <folder>/tls
    and reused. Invites, share-login links and machine join tokens carry
    that generated certificate's fingerprint for clients to pin; with
    --cert/--key (self-signed or not) they carry none, and clients check
    the certificate against their system trust store. The origin's host
    serves the API and the web app; each group's content (pages, files,
    page APIs) is served at <group>.<host>, the shared group at
    shared.<host>, so the certificate must cover both <host> and *.<host>.
    With --group-certificate/--group-private-key (a *.<host> leaf, needs
    --origin and --cert/--key) the listener presents it to the group
    hosts by SNI, and the --cert leaf to every other name. serve refuses
    to start with a group pair no handshake can use: a key on no named curve (P-256, P-384,
    P-521; RSA and Ed25519 also work, though macOS's system curl, built
    on LibreSSL, fails an Ed25519 handshake) or one that isn't the leaf's.
    --web-app serves the SPA from <dir> (loaded once at boot; index.html
    required) instead of the embedded build; the override is logged at boot.
    --host sets the bind address; it defaults to 127.0.0.1 (loopback
    only). Pass --host 0.0.0.0 to expose the server on the LAN.
    --origin advertises the server's canonical https:// origin through
    /v1/server discovery; share-login and machine join links
    are minted against it instead of the minting wallet's own address,
    and its host is the one group hosts are named under. Without it the
    group hosts are <group>.localhost:<port>, which only a browser on this
    machine reaches: serving group content to other devices needs --origin.
    serve uses this value and persists it to the database at boot (NULL when
    absent), alongside the TLS fingerprint and whether it is the generated
    certificate, for offline verbs like wuhu user invite; argv stays
    authoritative at runtime.
    Auth walls are on by default: API calls need an enrolled device and
    web-content reads need a live browser read session. --public-read
    opens content reads of the shared group (shared.<host>) to anyone, a
    public board; group hosts still need a read session, and writes stay
    walled.
    --dev drops both walls for local iteration.
    --web-port and --web-origin are deprecated and ignored: serve prints a
    warning for each; remove them.
    \(exitCodes)
    """,
    "machine": """
    usage: wuhu machine <add|join|run|list|name|rotate|revoke|move> ...

    a <machine> argument is the machine's name or its mc_ id.

    subcommands:
      add [--name N]              mint a machine and its join token (shown once)
      join <server-url> [fingerprint] [--name N] < token
                                  enroll this box's own key via the stdin token and persist the agent config
      run                         run the machine agent in the foreground (dial loop)
      list                        list machines with name and attachment state
      name <machine> <name>       rename a machine
      rotate <machine>            kick the machine's key and mint a fresh join token
      revoke <machine>            kick the machine's key; it cannot connect until rotated
      move <machine> --group G    move a machine to group G (admin of both groups)
    \(exitCodes)
    """,
    "machine add": """
    usage: wuhu machine add [--name N]

    mints a machine in the pinned space and prints its id, one-time join
    token, and, when the server runs its generated certificate, that
    certificate's fingerprint. the token is shown once and dies at first use.
    \(exitCodes)
    """,
    "machine join": """
    usage: wuhu machine join <server-url> [fingerprint] [--name N] < token

    the box claims --name, defaulting to its hostname; the server suffixes it
    until free, so a second box named mini joins as mini-2.
    generates this box's machine key, enrolls it by consuming the join token,
    and persists the key and agent config under ~/.wuhu/machine. the token is
    read from stdin (one trailing line ending is stripped), never from
    arguments: argv leaks via ps. a fingerprint (printed by machine add) is
    recorded into the user trust store before the first dial. without one, a
    server that passes system trust drops any pin an earlier join recorded for
    the host; one that does not is reached through that pin, which stays, and
    with no pin the join fails.
    start the agent with: wuhu machine run
    \(exitCodes)
    """,
    "machine run": """
    usage: wuhu machine run

    runs the machine agent in the foreground: dials the joined server forever,
    serves exec/fs/search, and logs to stderr. stop with ctrl-c.
    \(exitCodes)
    """,
    "device": """
    usage: wuhu device <list|set> ...

    devices are the app installs signed into this space; each registers itself
    on every connect. annotations here are the only part a person writes.
    \(exitCodes)
    """,
    "device list": """
    usage: wuhu device list

    lists devices as: <id> <kind> <machine|-> <name>
    \(exitCodes)
    """,
    "device set": """
    usage: wuhu device set <device> [--name <name>] [--machine <machine>]

    renames a device, and/or records which enrolled machine it is; <machine>
    is an mc_ id or a machine name. omitted fields are left alone.
    \(exitCodes)
    """,
    "machine list": """
    usage: wuhu machine list

    lists machines as: <name|-> <id> <attached|detached>
    \(exitCodes)
    """,
    "machine name": """
    usage: wuhu machine name <machine> <name>

    renames a machine; needs an admin of the machine's group, as a move
    does. names are lowercased, unique per space, and match
    [a-z0-9][a-z0-9.-]{0,62}; the mc_ id never changes and both address the
    box in machines:// paths, exec, rotate, and revoke.
    \(exitCodes)
    """,
    "machine rotate": """
    usage: wuhu machine rotate <machine>

    kicks the machine's enrolled key (dropping any live connection) and mints
    a fresh join token. rejoin the box with it, same as a first join.
    \(exitCodes)
    """,
    "machine revoke": """
    usage: wuhu machine revoke <machine>

    kicks the machine's enrolled key and drops any live connection;
    rotate re-enables it.
    \(exitCodes)
    """,
    "machine move": """
    usage: wuhu machine move <machine> --group <group>

    moves a machine to another group: sessions of the groups that read
    that group may then exec on it. takes an admin of both the machine's
    group and the target. its notes under /_/machines/<name>/ move into the
    new group's tree in the same revision.
    \(exitCodes)
    """,
    "user": """
    usage: wuhu user <add|reset|invite> --space <folder> ... | wuhu user <list|remove|handle|profile> ...

    add/reset/invite are offline recovery: they operate directly on
    <folder>/space.sqlite with the server stopped. possession of the space
    folder is root; there is no localhost side channel. list/remove run
    against the pinned space server and require an admin account.

    subcommands:
      add [--name N] [--admin] --space <folder>  create a human account and print its id
      reset --space <folder> <account-id>  delete the account's keys and read sessions
      invite [--server <url>] [--ttl <seconds>] --space <folder> <account-id>
                                           mint a one-time device invite link for the account
      list                                 list the pinned space's accounts (admin)
      remove <account-id>                  remove an account; its keys and browser
                                           logins die, its history stays (admin)
      handle <handle> [--display-name T]   claim your own display handle in the pinned space
      profile                              print your own directory entry
    \(exitCodes)
    """,
    "user handle": """
    usage: wuhu user handle <handle> [--display-name <text>]

    claims a display handle for the identity this device holds in the pinned
    space. handles are lowercased, unique per space, renameable, and match
    [a-z0-9][a-z0-9-]{1,31}. a handle is display only: it never logs in and
    never appears in auth — the persona name stays the principal.
    \(exitCodes)
    """,
    "user profile": """
    usage: wuhu user profile

    prints this device's own entry in the space directory: handle, principal,
    and display name.
    \(exitCodes)
    """,
    "user add": """
    usage: wuhu user add --space <folder> [--name N] [--admin]

    creates a human account directly in <folder>/space.sqlite (run with the
    server stopped) and prints its account id. each run creates a new
    account; device keys are enrolled separately. --admin marks the account
    as a space admin; the first account of an adminless space becomes admin
    without the flag — offline add is also the recovery path when every
    admin is gone.
    \(exitCodes)
    """,
    "user list": """
    usage: wuhu user list

    lists the pinned space's accounts (admin only): id, kind, admin marker,
    and name, one per line.
    \(exitCodes)
    """,
    "user remove": """
    usage: wuhu user remove <account-id>

    removes a human account from the pinned space (admin only). every device
    key, browser login, and outstanding invite of the account dies; authored
    history and attribution stay. refuses to remove the last admin.
    \(exitCodes)
    """,
    "user reset": """
    usage: wuhu user reset --space <folder> <account-id>

    deletes every key and browser login for the account directly in
    <folder>/space.sqlite (run with the server stopped). the account itself
    is kept; re-enroll devices afterwards.
    \(exitCodes)
    """,
    "user invite": """
    usage: wuhu user invite --space <folder> [--server <url>] [--ttl <seconds>] <account-id>

    mints a one-time device join token for the account directly in
    <folder>/space.sqlite (run with the server stopped) and prints the
    complete invite link (https://host:port/_/enroll#token=...&space=...[&fp=...])
    for wuhu login or the browser. this is the device-zero bootstrap: it
    needs no enrolled device and no --dev window.

    the server address comes from the deployment record the server persists
    at boot, and so does the fp: present only when that boot ran the
    generated certificate, absent under --cert/--key or when the record
    predates this distinction (boot the server once to fix that).
    --server overrides the recorded address, but a recorded fp stays
    attached — the override must reach the same TLS leaf. without either
    address, the verb fails: pass --server, or boot the server once with
    --origin. the token expires after --ttl seconds (default 3600).
    \(exitCodes)
    """,
    "key": """
    usage: wuhu key <list|revoke> ...

    device-key management against the pinned space. any account manages its
    own keys; keys of other accounts require an admin account.

    subcommands:
      list [--account <account-id>]  list keys (default: your own account's)
      revoke <pubkey>                kick a key; the device must re-enroll
    \(exitCodes)
    """,
    "key list": """
    usage: wuhu key list [--account <account-id>]

    lists enrolled keys, one per line: pubkey, capabilities, and expiry.
    defaults to your own account; --account needs admin (or your own id).
    \(exitCodes)
    """,
    "key revoke": """
    usage: wuhu key revoke <pubkey>

    revokes the named key in the pinned space; any assertion it signs is
    refused from the next request. your own keys always; other accounts'
    keys require admin. revoking this device's own key locks this device
    out until re-enrolled (wuhu login < invite-link).
    \(exitCodes)
    """,
    "secret": """
    usage: wuhu secret <set|list|remove> ...

    subcommands:
      set <NAME>        store a space secret (value read from stdin)
      list              list secret names (values are never readable)
      remove <NAME>     delete a secret

    space secrets live on the server, outside the space's files and history,
    one store per group: every subcommand acts on the acting group's store.
    scripts (run_script) use them through wuhu:secret, and an exec's
    --secret ENV=NAME takes NAME from the store of the machine's group. here,
    setting a secret takes a person who is an admin of the group, and
    removing one a human admin. the CLI is a person's: a top-level agent sets its group's secrets
    through run_script (wuhu:secret set) instead. no surface returns a value.
    \(exitCodes)
    """,
    "secret set": """
    usage: wuhu secret set <NAME> < value

    creates or replaces a secret in the acting group; needs a person who is
    an admin of the group (a top-level agent uses run_script's wuhu:secret). the value is read from stdin (one trailing newline is stripped),
    never from arguments: argv leaks via ps.
    \(exitCodes)
    """,
    "secret list": """
    usage: wuhu secret list

    prints the acting group's secret names, one per line. values are never
    readable.
    \(exitCodes)
    """,
    "secret remove": """
    usage: wuhu secret remove <NAME>

    deletes a secret from the acting group; needs a human admin of the group.
    \(exitCodes)
    """,
    "group": """
    usage: wuhu group <list|use|current|set> ...

    subcommands:
      list              list the space's group ids
      use <id>|--clear  record the group this wallet acts in, or clear it
      current           print the acting group and where it comes from
      set <id> ...      change a group's settings

    a request names its group in a Wuhu-Group header, from --group <id>, else
    WUHU_GROUP, else the wallet's group; with none it sends no header and the
    server picks. naming a group on a server without groups fails instead of
    acting elsewhere. a session's exec always acts in its session's group, so
    --group and WUHU_GROUP are refused there.
    \(exitCodes)
    """,
    "group list": """
    usage: wuhu group list

    prints the pinned space's group ids, one per line (GET /v1/groups).
    \(exitCodes)
    """,
    "group use": """
    usage: wuhu group use <id> | wuhu group use --clear

    records <id> as this wallet's group in .wuhu/config.json, after checking
    the server has it; --clear removes it. --group and WUHU_GROUP still win.
    \(exitCodes)
    """,
    "group current": """
    usage: wuhu group current

    prints the selected group and its source (--group, WUHU_GROUP or
    .wuhu/config.json). with none, prints the group the server picks for
    this caller, or none on a server without groups.
    \(exitCodes)
    """,
    "group set": """
    usage: wuhu group set --space-layer on|off <id>

    whether the sessions of group <id> render the space-wide instruction
    layer (shared's /AGENTS.md and skills); they pick the change up at their
    next turn. only an admin of the group may (PUT /v1/groups/<id>).
    \(exitCodes)
    """,
    "exec": """
    usage: wuhu exec --cwd machines://<name-or-id>/<path> [flags] -- <command...>

    runs <command...> (argv, no shell) on the machine, streaming duplex:
    local stdin -> command stdin (immediate EOF when stdin is a terminal),
    command stdout/stderr -> local stdout/stderr byte-exact, diagnostics on
    stderr only. reconnects automatically across network blips.

    flags:
      --secret ENV=NAME  inject secret NAME of the machine's group as $ENV (repeatable); output is masked
      --window N         flow-control window in bytes (default 4 MiB)
      --max-output N     kill the command once total output reaches N bytes (default unlimited)
      --timeout SECS     kill the command after SECS wall-clock seconds (default none)

    exit codes:
      N       command exited with code N
      128+SIG command died on signal SIG (kill, timeout, --max-output)
      125     machine lost: the machine stayed detached past the server grace; output is partial
      124     exec cancelled server-side (killed while the machine was detached, or caller-grace expiry)
      123     command finished but its output tail is no longer replayable; output is incomplete
      122     server unreachable: reconnect attempts exhausted
      64      usage error
      1       runtime error
    """,
    "skill": """
    usage: wuhu skill <export>

    subcommands:
      export  install the bundled agent skills into coding agent homes
    \(exitCodes)
    """,
    "skill export": """
    usage: wuhu skill export

    installs the bundled wuhu agent skills into $HOME/.claude/skills/<name>/SKILL.md
    (Claude Code) and $HOME/.agents/skills/<name>/SKILL.md (the Agent Skills
    standard location, read by Codex CLI and pi).

    idempotent: prints one line per file (wrote/updated/unchanged), and skips
    any existing SKILL.md it did not install itself.
    \(exitCodes)
    """,
    "tool-roster": """
    usage: wuhu tool-roster [--executor kernel|claude-code] [--json]

    prints the tool roster the pinned space hands its sessions, straight from
    the server's own declaration: kernel sessions get the base roster plus the
    transcript tools the loop executes itself (bookmark, compact); Claude Code
    sessions get the base roster over MCP and compact on their own.

    without --executor both rosters are printed. --json prints the raw
    GET /v1/session-tools payload, parameter JSON Schemas included.
    \(exitCodes)
    """,
    "usage": """
    usage: wuhu usage [--json]

    prints the plan usage the pinned space's server last observed per
    provider: every codex and claude provider, window by window, with its
    reset time. inference refreshes it as a side effect; the server reads it
    itself when a provider has gone fifteen minutes unobserved.
    \(exitCodes)
    """,
    "models": """
    usage: wuhu models <update>

    subcommands:
      update  sync /models.json in the pinned space from the published basis
    \(exitCodes)
    """,
    "auth": """
    usage: wuhu auth <set|list|remove|login|logout> [provider]

    manages server provider credentials (inference and capabilities) for the pinned space, stored per space id
    in ~/.wuhu/credentials/<space-id>.json on this host. the space server reads
    that file at inference time, so run these on the host that serves the
    space. environment variables (<PROVIDER>_API_KEY) override the store.

    subcommands:
      set <provider>     store an api key (read from stdin)
      list               show stored credentials (values redacted)
      remove <provider>  drop a stored credential
      login <provider>   ChatGPT device login (codex) or Claude Code setup token (claude dialect)
      logout <provider>  revoke ChatGPT login or drop Claude Code token
    \(exitCodes)
    """,
    "auth set": """
    usage: wuhu auth set <provider> < key.txt

    stores an api key for <provider> (a credential id from /models.json or /capabilities.json), read
    from stdin. replaces any credential already stored for that provider.
    \(exitCodes)
    """,
    "auth login": """
    usage: wuhu auth login <provider>

    chooses the login flow from <provider> in /models.json: codex uses the
    ChatGPT device-code flow; claude installs pinned Claude Code and stores the
    setup token read from stdin, or prompted for at a terminal.
    \(exitCodes)
    """,
    "send": """
    usage: wuhu send <session-id> <message> [--wait [--timeout SECONDS]] [--attach PATH ...]

    posts <message> as your persona (or the owner if unenrolled), in your local
    timezone, into the agent's box. the session answers there with
    send_message. a task takes no messages from people: the server refuses a
    send to one. run by a session, send reaches a task in that session's DM
    with it.
    flags:
      --wait     block until the session posts back into that conversation.
                 exits nonzero if the session errors (or is already errored)
      --timeout  give up waiting after SECONDS (exit nonzero)
      --attach   attach a local file of any type (repeatable, at most 8,
                 50 MiB each, 150 MiB in all). the files are uploaded with
                 the post; the server stores them write-once under
                 /_/conversations/<id>/attachments/YYYY/MM/DD/HHmmssZ/
                 <file name> and references that copy from the message.
                 the session sees a png, jpeg, gif or webp as an image and
                 any other file as its path, type and size.
    \(exitCodes)
    """,
    "inbox": """
    usage: wuhu inbox

    prints notifications above this wallet's client cursor for the pinned
    space, then advances the cursor. empty output means nothing new. one
    inbox and one cursor span all your groups, whatever --group says: each
    line names its group, and a sender from outside the conversation's group
    is shown with theirs.
    \(exitCodes)
    """,
    "session": """
    usage: wuhu session <create|request|restart|rename|tags|interrupt|resume|compact|archive|unarchive|log|entry|list> ...

    subcommands:
      create [--kind agent|task] [--top-level] [--executor E] [--provider P --model M] [--effort E] [--template NAME] [--extra JSON] [--tag T]... <title>
      request [--deadline SECONDS] <session-id> <message>
                               from a session's exec: open a request on a
                               child it created, which owes it a final report
      restart [--executor E] [--provider P] [--model M] [--effort E] [--extra JSON] [--message TEXT] <session-id>
                               wipe the transcript to a fresh generation,
                               keeping the id; optionally switch executor
      rename <session-id> <title>
                               set a session's title
      tags <session-id> [tag]...
                               replace a session's whole tag list; no tags
                               clears it; archived sessions included
      interrupt <session-id>   stop after the current step; resume to continue
      resume <session-id>      clear interrupt/error and continue
      compact <session-id> [--instructions ...]
                               ask a session to fold its context at its next
                               quiet point; works on every executor
      archive <session-id> [--force]
                               archive its subtree; force interrupts busy
                               sessions and closes all open requests in
                               the subtree
      unarchive <session-id>   restore within the grace window
      log [--direct|-v|-vv] [--limit N] [--before REF] <session-id>  read the session log
      entry <session-id> <ref> fetch one log item in full
      list                     list sessions (sugar over query)
    \(exitCodes)
    """,
    "session create": """
    usage: wuhu session create [--kind agent|task] [--top-level] [--home-group G] [--provider P --model M] [--effort E] [--template NAME] [--tag T]... <title>

    creates a session (and its owning channel), inert until something is
    posted to it. --provider and --model are required, validated against the
    space's /models.json; the provider's dialect picks who runs the session
    (a claude provider runs Claude Code, every other one the kernel loop).
    --effort defaults to the model's declared default. a person creates
    agents only: --kind task, or a task template, is refused.

    --template NAME merges /templates/<NAME>/template.json in the acting
    group — a JSON object of these same parameters plus kind and description —
    underneath the explicit flags; flags win field by field; another group's
    is wuhu://<group>.localspace/templates/<NAME>. The template's other files
    are cloned into the new session's home, /_/sessions/<id>/.

    from a session's exec (WUHU_EXEC=1) the new session is that session's
    child, in its group: a task unless --kind agent, on the parent's own model
    unless --provider/--model name another. --top-level creates a top-level
    agent that belongs to the humans instead; only an agent may.

    --home-group G places a top-level agent in group G instead of the acting
    group, which must read G; a child always lives in its creator's group.
    \(exitCodes)
    """,
    "session request": """
    usage: wuhu session request [--deadline SECONDS] <session-id> <message>

    only from a session's exec (WUHU_EXEC=1): opens a request on a child the
    session created, posting <message> into their DM. the child owes a final
    report; --deadline notifies the session if none arrives in time. prints
    the request id and the DM's conversation id.
    \(exitCodes)
    """,
    "session restart": """
    usage: wuhu session restart [--provider P] [--model M] [--effort E] [--message TEXT] <session-id>

    starts the session over: the id, its box, its DMs and its home folder
    /_/sessions/<id>/ are kept; the transcript is wiped to a fresh, empty
    generation and the old one is archived unread. undrained queue rows are
    dropped, subscriptions and timers are cancelled, and an errored or
    interrupted session comes back normal.

    refused while the session has unfinished work or an open run — interrupt
    it or let it settle first.

    omitted fields keep the session's current spec, so a bare restart is a
    pure wipe; naming another provider keeps nothing of the old model. the
    resulting spec is validated exactly as `session create` validates a new
    one. a session left from the removed contractor executor comes back only
    this way, with --provider and --model.

    --message posts an opening message so the fresh session starts working.
    \(exitCodes)
    """,
    "session log": """
    usage: wuhu session log [--direct|-v|-vv] [--limit N] [--before REF] <session-id>

    default: the session's channel — threads, senders, replies (every
    executor; the primary view).

    --direct switches to the deep per-session log; levels select kinds:
      --direct  narrative: inputs, reminders, assistant text, replies,
                compaction markers
      -v        plus tool calls, reasoning summaries, cumulative context usage
      -vv       plus tool results

    every direct-view item carries a [ref]; `wuhu session entry` fetches one
    in full. both views serve the tail (last 50 by default); --limit N caps
    the page and --before pages older items — the [n] cursor in the channel
    view, a [ref] in the direct view. refs are short-lived — compaction
    invalidates them. a Claude Code session's direct view is translated
    from its stored log: wuhu tools under their own names, Claude Code's as
    ClaudeRead, ClaudeWrite, ClaudeEdit and WebSearch.
    \(exitCodes)
    """,
    "session entry": """
    usage: wuhu session entry <session-id> <ref>

    prints one session log item in full, unclipped. take REF from a
    `wuhu session log --direct` header. refs are short-lived handles;
    a compacted or trimmed ref answers with a typed error — re-read the log.
    \(exitCodes)
    """,
    "models update": """
    usage: wuhu models update

    merges the published well-known models basis into /models.json in the
    pinned space: missing providers and models are added, existing entries
    keep your edits, nothing is removed. writes through the journal.
    (the published basis is currently a seed bundled with the CLI.)
    \(exitCodes)
    """,
    "ps": """
    usage: wuhu ps

    lists live execs as: <exec-id> <machine-id> <started> <command>
    \(exitCodes)
    """,
    "kill": """
    usage: wuhu kill <exec-id>

    sends the kill frame; the machine agent kills the process group it owns.
    \(exitCodes)
    """,
  ]
}

struct ArgumentCursor {
  private var arguments: [String]

  init(_ arguments: [String]) {
    self.arguments = arguments
  }

  mutating func pop() -> String? {
    guard !self.arguments.isEmpty else { return nil }
    if self.arguments[0] == "--" {
      self.arguments.removeFirst()
      guard !self.arguments.isEmpty else { return nil }
    }
    return self.arguments.removeFirst()
  }

  mutating func required(_ name: String, verb: String) throws -> String {
    guard let value = self.pop() else {
      throw UsageError(message: "\(verb): missing <\(name)>")
    }
    return value
  }

  mutating func requiredInt(_ name: String, verb: String) throws -> Int {
    let text = try self.required(name, verb: verb)
    guard let value = Int(text) else {
      throw UsageError(message: "\(verb): <\(name)> must be an integer")
    }
    return value
  }

  mutating func flag(_ name: String) -> Bool {
    guard let index = self.optionIndex(of: name) else { return false }
    self.arguments.remove(at: index)
    return true
  }

  mutating func option(_ name: String, verb: String) throws -> String? {
    guard let index = self.optionIndex(of: name) else { return nil }
    let valueIndex = self.arguments.index(after: index)
    guard valueIndex < self.arguments.endIndex else {
      throw UsageError(message: "\(verb): \(name) wants a value")
    }
    let value = self.arguments[valueIndex]
    self.arguments.remove(at: valueIndex)
    self.arguments.remove(at: index)
    return value
  }

  mutating func intOption(_ name: String, verb: String) throws -> Int? {
    guard let text = try self.option(name, verb: verb) else { return nil }
    guard let value = Int(text) else {
      throw UsageError(message: "\(verb): \(name) wants an integer")
    }
    return value
  }

  mutating func doubleOption(_ name: String, verb: String) throws -> Double? {
    guard let text = try self.option(name, verb: verb) else { return nil }
    guard let value = Double(text), value.isFinite else {
      throw UsageError(message: "\(verb): \(name) wants a number")
    }
    return value
  }

  func finish(verb: String) throws {
    let remaining = self.arguments.filter { $0 != "--" }
    if let extra = remaining.first {
      throw UsageError(message: "\(verb): unexpected argument \(extra)")
    }
  }

  var isFinished: Bool {
    self.arguments.allSatisfy { $0 == "--" }
  }

  var remaining: [String] {
    self.arguments
  }

  var hasHelp: Bool {
    self.arguments.contains("--help") || self.arguments.contains("-h")
  }

  private func optionIndex(of name: String) -> [String].Index? {
    let end = self.arguments.firstIndex(of: "--") ?? self.arguments.endIndex
    return self.arguments[..<end].firstIndex(of: name)
  }
}

/// An IPv4 or IPv6 literal, which has no subdomains to name group hosts.
private func isIPLiteral(_ host: String) -> Bool {
  if host.contains(":") { return true }
  let parts = host.split(separator: ".", omittingEmptySubsequences: false)
  return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
}
