import struct Credentials.CredentialResolver
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.AttemptTraceClient
import struct InferenceKit.InferenceMetric
import struct InferenceKit.ModelsDocument
import struct InferenceKit.ProviderCatalog
import JSONValue
import SessionDomain
import SpaceClient
import SpaceContract
import SpaceCore
import enum WuhuAI.InferenceError
import protocol WuhuAI.MediaResolver

/// What the worker brings to an inference of its own: the provider credentials
/// it holds, the OIDC signing done for it, and where it traces attempts.
/// Everything else an inference needs comes from main as the session: the
/// models catalog, the frozen prompt home, media, and the record of the attempt.
public struct InferenceAccess: Sendable {
  public var credentials: CredentialResolver
  public var oidcToken: (@Sendable (URL, SessionID) async throws -> String)?
  public var oidcReadiness: (@Sendable (URL) async throws -> Void)?
  public var oidcBindingIdentity: (@Sendable (URL, SessionID) async throws -> String?)?
  public var trace: AttemptTraceClient?

  public init(
    credentials: CredentialResolver = .unavailable,
    oidcToken: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    oidcReadiness: (@Sendable (URL) async throws -> Void)? = nil,
    oidcBindingIdentity: (@Sendable (URL, SessionID) async throws -> String?)? = nil,
    trace: AttemptTraceClient? = nil,
  ) {
    self.credentials = credentials
    self.oidcToken = oidcToken
    self.oidcReadiness = oidcReadiness
    self.oidcBindingIdentity = oidcBindingIdentity
    self.trace = trace
  }

  /// The catalog over a models document, signing with this access; without
  /// `oidcToken` the catalog refuses OIDC providers as not configured.
  public func catalog(
    _ document: ModelsDocument,
    receiveCodexResponseHeaders: @escaping @Sendable (String, [String: String]) async -> Void = { _, _ in },
  ) -> ProviderCatalog {
    ProviderCatalog(
      document: document,
      credentials: credentials,
      oidcToken: oidcToken,
      oidcReadiness: oidcReadiness,
      oidcBindingIdentity: oidcBindingIdentity,
      receiveCodexResponseHeaders: receiveCodexResponseHeaders,
    )
  }
}

extension ToolExecutor {
  /// The provider catalog as the session reads it: `/models.json` from the
  /// settings group, with `/model-groups.json` when asked, signed with the
  /// worker's access.
  public func catalog(
    _ session: SessionID,
    includeGroups: Bool,
    receiveCodexResponseHeaders: @escaping @Sendable (String, [String: String]) async -> Void = { _, _ in },
  ) async throws -> ProviderCatalog {
    guard let models = try await settingsDocument(session, ModelsDocument.spacePath) else { throw SpaceError.notFound(ModelsDocument.spacePath) }
    let groups = includeGroups ? try await settingsDocument(session, ModelsDocument.groupPath) : nil
    return access.catalog(try ModelsDocument(json: models, groupsJSON: groups), receiveCodexResponseHeaders: receiveCodexResponseHeaders)
  }

  /// The session's prompt home, frozen at its prompt revision (`GET /v1/prompt`).
  public func promptHome(_ session: SessionID) async throws -> SessionHome {
    let output: SessionPromptOutput = try await client(session).api(.get, "/v1/prompt")
    return SessionHome(
      path: output.home, group: GroupID(rawValue: output.group),
      groupLayer: scope(output.groupLayer), home: scope(output.homeLayer),
    )
  }

  /// Media a transcript of `session` names, read as the session.
  public func mediaResolver(_ session: SessionID, limits: ImageLimits) -> any MediaResolver {
    ClientMediaResolver(tools: self, session: session, limits: limits)
  }

  /// One inference attempt, reported to main for the session that ran it (`POST /v1/inferences`).
  public func report(_ metric: InferenceMetric) async throws {
    let input = InferenceReportInput(
      id: metric.id, timestamp: metric.timestamp.timeIntervalSince1970, provider: metric.provider, model: metric.model,
      servedModel: metric.servedModel, effort: metric.effort, outcome: metric.outcome.rawValue,
      errorKind: metric.errorKind, status: metric.status, ttftMs: metric.ttftMs.map(Int.init), durationMs: Int(metric.durationMs),
      usage: metric.usage.map {
        InferenceUsageInput(
          inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens,
          cacheWriteTokens: $0.cacheWriteTokens, reasoningTokens: $0.reasoningTokens, totalTokens: $0.totalTokens,
        )
      },
    )
    let _: JSONValue = try await client(metric.session).api(.post, "/v1/inferences", body: try JSONValueEncoder().encode(input))
  }
}

private func scope(_ scope: PromptScope) -> InstructionScope {
  InstructionScope(
    sections: scope.sections.map { SessionHome.Section(path: $0.path, text: $0.text) },
    skills: scope.skills.map { SessionHome.Skill(name: $0.name, description: $0.description, path: $0.path) },
  )
}
