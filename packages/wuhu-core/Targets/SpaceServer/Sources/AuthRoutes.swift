#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Assertion
import Dependencies
import Fetch
import Serve
import ServeRouting
import SpaceContract
import SpaceCore

func addAuthRoutes(_ router: inout Router, space: Space, challenges: OneShotChallenges, fingerprint: String?, dev: Bool) {
  @Dependency(\.date) var dateGen
  // Personas are allocator draws recorded against the minting key, so the
  // route re-verifies the bearer itself: even behind a --dev wall the draw
  // must trace persona -> key -> account or not happen at all. Adoption keeps
  // the route idempotent: a wallet that lost its cache converges back onto
  // the account's earliest persona instead of forking a new one.
  router.post("/v1/persona") { request, _ in
    try request.requireNoBody()
    switch try await bearerVerdict(request: request, space: space, now: dateGen.now) {
    case let .verified(credential):
      let persona = try await space.adoptPersona(key: credential.key)
      return try Response.json(PersonaMintOutput(persona: persona.name))
    case let .rejected(response):
      return response
    case .anonymous:
      return errorResponse(
        .unauthorized,
        code: "unauthorized",
        message: "personas are minted for enrolled devices only",
        hint: "enroll this device: wuhu login < invite-link (mint one on an enrolled device: wuhu share-login)",
      )
    }
  }

  // Bare self-revocation: the assertion names the key row it kills, so
  // possession of the key is the entire authority. An addressed body widens
  // that to the actor's own keys, or any key for an admin.
  router.delete("/v1/key") { request, _ in
    guard request.body != nil else {
      switch try await bearerVerdict(request: request, space: space, now: dateGen.now) {
      case let .verified(credential):
        // Idempotent: a racing revoke with the same bearer removes the row first,
        // and the loser must still see success rather than a 500.
        do {
          try await space.removeKey(pubkey: credential.key.pubkey)
        } catch SpaceError.notFound {}
        return Response(status: .noContent)
      case let .rejected(response):
        return response
      case .anonymous:
        return errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required")
      }
    }
    let input = try await request.json(KeyRevokeInput.self)
    switch try await managementVerdict(request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response):
      return response
    case let .actor(actor):
      guard let key = try await space.keyRecord(pubkey: input.pubkey) else {
        return errorResponse(.notFound, code: "notFound", message: "unknown key: \(input.pubkey)")
      }
      guard actor.mayManage(key.account) else {
        return adminRequired("revoking another account's key")
      }
      do {
        try await space.removeKey(pubkey: input.pubkey)
      } catch SpaceError.notFound {}
      return jsonResponse(.object([:]))
    }
  }

  router.get("/v1/keys") { request, _ in
    switch try await managementVerdict(request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response):
      return response
    case let .actor(actor):
      let requested = queryValues(of: request.url)["account"]
      let target: AccountID
      switch (requested, actor) {
      case let (raw?, _):
        guard AccountID.isValid(raw) else {
          return errorResponse(.badRequest, code: "invalidArgument", message: "malformed account id: \(raw)")
        }
        target = AccountID(rawValue: raw)
      case let (nil, .account(record)):
        target = record.id
      case (nil, .devOwner):
        return errorResponse(
          .badRequest,
          code: "invalidArgument",
          message: "the --dev seat has no account of its own; pass account=<id>",
        )
      }
      guard actor.mayManage(target) else {
        return adminRequired("listing another account's keys")
      }
      let keys = try await space.keys(account: target)
      return try Response.json(KeyListOutput(keys: keys.map(keyPayload)))
    }
  }

  // Invite minting is self-or-admin: an enrolled device re-invites its own
  // account freely, but only an admin mints for someone else.
  router.post("/v1/enroll") { request, _ in
    let actor: ManagementActor
    switch try await managementVerdict(request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response):
      return response
    case let .actor(resolved):
      actor = resolved
    }
    let input = try await request.json(EnrollMintInput.self)
    guard AccountID.isValid(input.account) else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "malformed account id: \(input.account)")
    }
    guard actor.mayManage(AccountID(rawValue: input.account)) else {
      return adminRequired("minting an invite for another account")
    }
    guard let capabilities = capabilitySet(input.capabilities) else {
      return errorResponse(
        .badRequest,
        code: "invalidArgument",
        message: "capabilities must be a non-empty subset of \(mintableCapabilities.map(\.rawValue).joined(separator: "|"))",
      )
    }
    let ttl = input.ttlSeconds ?? 3600
    guard ttl > 0 else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "ttlSeconds must be positive")
    }
    do {
      let minted = try await space.mintJoinToken(
        account: AccountID(rawValue: input.account),
        capabilities: capabilities,
        createdBy: actor.accountID,
        lifetime: TimeInterval(ttl),
      )
      return try Response.json(EnrollMintOutput(
        token: minted.token.rawValue,
        expiresAt: minted.expiresAt.timeIntervalSince1970,
        space: try await space.identity().rawValue,
        fingerprint: fingerprint,
      ))
    } catch is SpaceError {
      return errorResponse(.notFound, code: "notFound", message: "unknown account: \(input.account)")
    }
  }

  router.post("/v1/enroll/revoke") { request, _ in
    let actor: ManagementActor
    switch try await managementVerdict(request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response):
      return response
    case let .actor(resolved):
      actor = resolved
    }
    let input = try await request.json(EnrollRevokeInput.self)
    do {
      guard try await space.revokeJoinToken(
        JoinToken(rawValue: input.token),
        revocableBy: { actor.mayManage($0) },
      ) != nil else {
        return errorResponse(.notFound, code: "notFound", message: "no live invite for that token")
      }
      return jsonResponse(.object([:]))
    } catch is JoinTokenRevocationRefused {
      return adminRequired("revoking another account's invite")
    }
  }

  // consume authenticates by the token itself: it must stay reachable without
  // any prior credential, because the key it enrolls does not exist yet.
  router.post("/v1/enroll/consume") { request, _ in
    let input = try await request.json(EnrollConsumeInput.self)
    do {
      let key = try await space.consumeJoinToken(JoinToken(rawValue: input.token), pubkey: input.pubkey)
      var machine = try await space.machine(account: key.account)
      // A join names an unnamed box only. A machine that already carries a
      // name keeps it: renaming is `PUT /v1/machine/:id/name`, never a
      // side effect of rejoining from a differently-named host.
      if let joining = machine, joining.name == nil,
         let preferred = input.name, let normalized = MachineName.normalized(preferred)
      {
        machine = try await space.claimMachineName(joining.id, preferred: normalized)
      }
      return try Response.json(EnrollConsumeOutput(
        account: key.account.rawValue,
        capabilities: key.capabilities.map(\.rawValue).sorted(),
        machine: machine?.id.rawValue,
        machineName: machine?.name,
      ))
    } catch is JoinTokenRejected {
      return errorResponse(.unauthorized, code: "tokenInvalid", message: "join token rejected")
    } catch SpaceError.malformedPubkey(let pubkey) {
      return errorResponse(
        .badRequest,
        code: "invalidArgument",
        message: "malformed pubkey: \(pubkey)",
        hint: "expected ed25519:<base64 raw key> or p256:<base64 x963 key>",
      )
    } catch is SpaceError {
      return errorResponse(.conflict, code: "alreadyEnrolled", message: "this key is already enrolled here")
    }
  }

  router.get("/v1/enroll/share-login/challenge") { _, _ in
    try Response.json(ShareLoginChallengeOutput(challenge: challenges.mint()))
  }

  // The signature gate: the minter proves possession of an enrolled key by
  // signing a server-minted one-shot challenge; the pubkey only names the live
  // key row the signature is verified against, it authenticates nothing.
  router.post("/v1/enroll/share-login") { request, _ in
    let input = try await request.json(ShareLoginInput.self)
    let ttl = input.ttlSeconds ?? ShareLogin.defaultTTLSeconds
    guard ttl > 0, ttl <= ShareLogin.maximumTTLSeconds else {
      return errorResponse(
        .badRequest,
        code: "invalidArgument",
        message: "ttlSeconds must be between 1 and \(ShareLogin.maximumTTLSeconds)",
      )
    }
    guard challenges.take(input.challenge),
          verifiedShareLoginSignature(input),
          let credential = try await space.credential(pubkey: input.pubkey)
    else {
      return errorResponse(.unauthorized, code: "keyInvalid", message: "share-login handshake rejected")
    }
    let minted = try await space.mintJoinToken(
      account: credential.account,
      capabilities: [.device],
      createdBy: credential.account,
      lifetime: TimeInterval(ttl),
    )
    return try Response.json(ShareLoginOutput(
      token: minted.token.rawValue,
      expiresAt: minted.expiresAt.timeIntervalSince1970,
      space: try await space.identity().rawValue,
      fingerprint: fingerprint,
    ))
  }
}

private func verifiedShareLoginSignature(_ input: ShareLoginInput) -> Bool {
  guard let key = VerifyingKey(label: input.pubkey),
        let signature = Data(base64Encoded: input.signature)
  else { return false }
  return key.isValidSignature(signature, for: Data(ShareLogin.signingMessage(challenge: input.challenge).utf8))
}

func keyPayload(_ key: KeyRecord) -> KeyPayload {
  KeyPayload(
    pubkey: key.pubkey,
    account: key.account.rawValue,
    capabilities: key.capabilities.map(\.rawValue).sorted(),
    createdBy: key.createdBy?.rawValue,
    createdAt: key.createdAt.timeIntervalSince1970,
    expiresAt: key.expiresAt?.timeIntervalSince1970,
  )
}

// A contractor key still decodes from an old space, but none is minted.
private let mintableCapabilities: [KeyCapability] = KeyCapability.allCases.filter { $0 != .contractor }

private func capabilitySet(_ raw: [String]) -> Set<KeyCapability>? {
  guard !raw.isEmpty else { return nil }
  var capabilities: Set<KeyCapability> = []
  for value in raw {
    guard let capability = KeyCapability(rawValue: value), mintableCapabilities.contains(capability) else { return nil }
    capabilities.insert(capability)
  }
  return capabilities
}
