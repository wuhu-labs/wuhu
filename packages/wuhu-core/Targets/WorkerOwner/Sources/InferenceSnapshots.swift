#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.CredentialBinding
import enum Credentials.ProviderCredential
import struct InferenceKit.InferenceMetric
import enum SessionDomain.MediaReference
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import struct SpaceCore.InstructionScope
import struct SpaceCore.SessionHome
import struct WorkerProtocol.WorkerProtocolError
import struct WuhuAI.Usage

struct CredentialSnapshot: Codable, Sendable {
  let kind: String
  let value: String
  let account: String?
  init(_ credential: ProviderCredential) {
    switch credential {
    case let .apiKey(value): kind = "api-key"; self.value = value; account = nil
    case let .chatGPT(value, account): kind = "chatgpt"; self.value = value; self.account = account
    case let .claudeCodeOAuth(value): kind = "claude-code-oauth"; self.value = value; account = nil
    }
  }

  func credential() throws -> ProviderCredential {
    switch (kind, account) {
    case ("api-key", nil): .apiKey(value)
    case ("chatgpt", let account?): .chatGPT(accessToken: value, accountID: account)
    case ("claude-code-oauth", nil): .claudeCodeOAuth(value)
    default: throw WorkerProtocolError(.invalidMessage, message: "Invalid provider credential snapshot")
    }
  }
}

struct CredentialBindingSnapshot: Codable, Sendable {
  let credential: CredentialSnapshot
  let identityEpoch: String
  let permitsOpaqueReplay: Bool
  init(_ binding: CredentialBinding) {
    credential = .init(binding.credential); identityEpoch = binding.identityEpoch; permitsOpaqueReplay = binding.permitsOpaqueReplay
  }

  func binding() throws -> CredentialBinding {
    .init(credential: try credential.credential(), identityEpoch: identityEpoch, permitsOpaqueReplay: permitsOpaqueReplay)
  }
}

struct HomeSnapshot: Codable, Sendable {
  struct Scope: Codable, Sendable {
    struct Section: Codable, Sendable { let path: String; let text: String }
    struct Skill: Codable, Sendable { let name: String; let description: String; let path: String }
    let sections: [Section]
    let skills: [Skill]
    init(_ scope: InstructionScope) {
      sections = scope.sections.map { .init(path: $0.path, text: $0.text) }
      skills = scope.skills.map { .init(name: $0.name, description: $0.description, path: $0.path) }
    }

    var scope: InstructionScope {
      .init(sections: sections.map { .init(path: $0.path, text: $0.text) }, skills: skills.map { .init(name: $0.name, description: $0.description, path: $0.path) })
    }
  }

  let path: String
  let group: GroupID
  let spaceLayer: Scope
  let groupLayer: Scope
  let home: Scope
  init(_ home: SessionHome) {
    path = home.path; group = home.group; spaceLayer = .init(home.spaceLayer); groupLayer = .init(home.groupLayer); self.home = .init(home.home)
  }

  var value: SessionHome { .init(path: path, group: group, spaceLayer: spaceLayer.scope, groupLayer: groupLayer.scope, home: home.scope) }
}

struct MetricSnapshot: Codable, Sendable {
  let timestamp: Date
  let session: SessionID
  let provider: String
  let model: String
  let servedModel: String?
  let effort: String
  let outcome: String
  let errorKind: String?
  let status: Int?
  let ttftMs: Int64?
  let durationMs: Int64
  let usage: Usage?
  init(_ metric: InferenceMetric) {
    timestamp = metric.timestamp; session = metric.session; provider = metric.provider; model = metric.model; servedModel = metric.servedModel; effort = metric.effort; outcome = metric.outcome.rawValue; errorKind = metric.errorKind; status = metric.status; ttftMs = metric.ttftMs; durationMs = metric.durationMs; usage = metric.usage
  }

  func metric() throws -> InferenceMetric {
    guard let outcome = InferenceMetric.Outcome(rawValue: outcome) else { throw WorkerProtocolError(.invalidMessage, message: "Invalid inference metric outcome") }
    return .init(timestamp: timestamp, session: session, provider: provider, model: model, servedModel: servedModel, effort: effort, outcome: outcome, errorKind: errorKind, status: status, ttftMs: ttftMs, durationMs: durationMs, usage: usage)
  }
}

struct MediaSnapshot: Codable, Sendable {
  let kind: String
  let value: String
  init(_ reference: MediaReference) {
    switch reference { case let .blob(value): kind = "blob"; self.value = value; case let .spaceFile(value): kind = "space-file"; self.value = value }
  }

  func reference() throws -> MediaReference {
    switch kind { case "blob": .blob(value); case "space-file": .spaceFile(value); default: throw WorkerProtocolError(.invalidMessage, message: "Invalid media reference") }
  }
}
