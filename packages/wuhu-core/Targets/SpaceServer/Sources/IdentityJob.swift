#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import JSONValue
import Logging
import Wuwei

struct IdentityKeys: Sendable {
  var load: @Sendable (String) async throws -> ServerIdentity
  var store: @Sendable (ServerIdentity) async throws -> Void

  static func disk(_ directory: URL) -> Self {
    Self(load: { kid in
      do {
        guard let data = try await KeyFileStore.disk(directory.appendingPathComponent(kid + ".p256")).load() else { throw IdentityError.keyUnavailable }
        let key = try ServerIdentity(rawKey: data)
        guard key.kid == kid else { throw IdentityError.keyUnavailable }
        return key
      } catch { throw IdentityError.keyUnavailable }
    }, store: { key in
      let file = KeyFileStore.disk(directory.appendingPathComponent(key.kid + ".p256"))
      if let existing = try await file.load() {
        guard existing == key.rawKey else { throw IdentityError.keyUnavailable }
      } else {
        try await file.create(key.rawKey)
      }
    })
  }

  func jwks(_ kids: [String]) async throws -> JSONValue {
    var keys: [JSONValue] = []
    for kid in kids { keys += try await load(kid).jwks.object!["keys"]!.array! }
    return .object(["keys": .array(keys)])
  }
}

struct IdentityClient: Sendable, TestDependencyKey {
  var keys: IdentityKeys
  var fetch: FetchClient
  var uuid: @Sendable () -> UUID
  var sleep: @Sendable (Duration) async throws -> Void
  static var testValue: Self { preconditionFailure("IdentityClient must be provided") }
}

enum IdentityWorkResult: Codable, Sendable {
  case generated(String)
  case published(String?)
  case failed(IdentityError)
}

@Job
struct IdentityJob {
  struct Params: Codable {
    let cell: IdentityCell.ID
    let work: IdentityWork
  }

  typealias Message = Never

  mutating func start() async throws -> Outcome {
    let client = ctx.dependency(IdentityClient.self)
    let params = ctx.params
    let state = ctx.cell(params.cell).state()!
    precondition(state.pending?.id == params.work.id)
    let now = Date(timeIntervalSince1970: Double(ctx.now.milliseconds) / 1000)
    let result = try await ctx.effect {
      do {
        if params.work.action == .generate {
          let key = try ServerIdentity.generate()
          try await client.keys.store(key)
          return IdentityWorkResult.generated(key.kid)
        }
        let registration = params.work.action == .register || state.directoryID == nil
        let target = IdentityController.directoryOrigin + (registration ? "/register" : "/" + state.directoryID! + "/keys")
        let kids = params.work.action == .retire ? [state.schedule.signer] : state.schedule.keys
        let signer = try await client.keys.load(state.schedule.signer)
        let proof = try await signer.proof(audience: target, jwks: client.keys.jwks(kids), now: now, id: client.uuid())
        let request = Request(url: URL(string: target)!, method: registration ? .post : .put, body: .bytes(Data(proof.utf8), contentType: "application/jose"))
        let result = try await withThrowingTaskGroup(of: JSONValue.self) { tasks in
          tasks.addTask {
            let response = try await client.fetch(request)
            guard response.status == (registration ? .created : .ok) else {
              let body = try? await response.json(JSONValue.self, upTo: 4096)
              switch body?.object?["code"]?.stringValue {
              case "unknownId": throw IdentityError.unknownId
              case "unlistedKey": throw IdentityError.unlistedKey
              default: throw IdentityError.directoryUnavailable
              }
            }
            return try await response.json(JSONValue.self, upTo: 4096)
          }
          tasks.addTask {
            try await client.sleep(.seconds(15))
            throw IdentityError.directoryUnavailable
          }
          defer { tasks.cancelAll() }
          return try await tasks.next()!
        }
        guard result.object?["confirmed"] == .bool(true) else { throw IdentityError.directoryUnavailable }
        if registration {
          guard let id = result.object?["id"]?.stringValue, IdentityController.validID(id), result.object?["issuer"] == .string(IdentityController.directoryOrigin + "/" + id) else { throw IdentityError.directoryUnavailable }
          return .published(id)
        }
        return .published(nil)
      } catch {
        try Task.checkCancellation()
        let failure: IdentityError = switch (params.work.action, error as? IdentityError) {
        case (.generate, _): .keyUnavailable
        case (_, .unknownId): .unknownId
        case (_, .unlistedKey): .unlistedKey
        case (_, .keyUnavailable): .keyUnavailable
        default: .directoryUnavailable
        }
        Logger(label: "wuhu.identity").warning("identity work failed", metadata: ["code": "\(failure.workCode)"])
        return .failed(failure)
      }
    }
    return .done(sending: .finished(params.work, result), to: params.cell.recipient)
  }
}
