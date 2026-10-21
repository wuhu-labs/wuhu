import Credentials
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import SessionDomain
import SessionTools
import Synchronization
import Testing
import WuhuAI

private let oidcModels = #"{"offline":{"dialect":"anthropic","baseURL":"https://offline.test","auth":"oidc","models":{"small":{"maxInput":8192,"maxOutput":512,"efforts":["low"],"defaultEffort":"low"}}}}"#
private let small = ModelSpecifier(provider: "offline", model: "small", effort: "low")

// The worker's inference access: credentials and the OIDC signer the catalog
// signs with, forwarded with the calling session.
@Suite struct InferenceAccessTests {
  @Test func unconfiguredOIDCIsRefusedBeforeAnyCredentialRead() async throws {
    let access = InferenceAccess(credentials: .init { _ in
      Issue.record("OIDC must not read a stored credential")
      return nil
    })
    let catalog = access.catalog(try ModelsDocument(json: Data(oidcModels.utf8)))
    await #expect(throws: CatalogError.oidcNotConfigured(provider: "offline")) { try await catalog.validateReadiness(small) }
    do {
      _ = try await catalog.resolve(small, session: SessionID("caller"))
      Issue.record("unconfigured signing must fail")
    } catch let InferenceError.invalidInput(status, body) {
      #expect(status == 422)
      #expect(body == "OIDC authentication is not configured on this server.")
    }
  }

  @Test func configuredSignerIsForwardedWithTheCaller() async throws {
    let session = SessionID("caller")
    let audience = URL(string: "https://offline.test")!
    let signed = Mutex(0)
    let access = InferenceAccess(
      credentials: .init { _ in
        Issue.record("OIDC must not read a stored credential")
        return nil
      },
      oidcToken: { requested, caller in
        #expect(requested == audience && caller == session)
        signed.withLock { $0 += 1 }
        return "fixture-token"
      },
      oidcReadiness: { requested in #expect(requested == audience) },
      oidcBindingIdentity: { requested, caller in
        #expect(requested == audience && caller == session)
        return "stable-identity"
      },
    )
    let catalog = access.catalog(try ModelsDocument(json: Data(oidcModels.utf8)))
    try await catalog.validateReadiness(small)
    let resolved = try await catalog.resolve(small, session: session)
    #expect(resolved.specifier == small)
    #expect(signed.withLock { $0 } == 1)
  }
}
