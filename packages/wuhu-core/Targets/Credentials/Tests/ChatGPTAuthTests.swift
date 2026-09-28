#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import Credentials
import Dependencies
import Fetch
import Testing

private let tokens = ChatGPTTokens(
  idToken: nil,
  accessToken: "access.jwt",
  refreshToken: "refresh-value",
  accountID: "acct-1",
  expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
)

private func failing(_ error: any Error) -> FetchClient {
  FetchClient { _ in throw error }
}

@Suite struct ChatGPTAuthTests {
  @Test func refreshNamesTheHopItCouldNotReach() async throws {
    await withDependencies {
      $0.fetch = failing(FetchError.transportFailure(kind: .connectTimeout))
    } operation: {
      await #expect(throws: ChatGPTAuthError.unreachable(
        hop: "auth.openai.com to refresh ChatGPT credentials",
        kind: .connectTimeout,
      )) {
        try await ChatGPTAuth.refresh(tokens)
      }
    }
  }

  @Test func revokeNamesItsOwnHop() async throws {
    await withDependencies {
      $0.fetch = failing(FetchError.transportFailure(kind: .connectionClosed))
    } operation: {
      await #expect(throws: ChatGPTAuthError.unreachable(
        hop: "auth.openai.com to revoke ChatGPT credentials",
        kind: .connectionClosed,
      )) {
        try await ChatGPTAuth.revoke(tokens)
      }
    }
  }

  // Only transport failures are restated; a protocol-shaped FetchError is not
  // a reachability claim and must pass through for the status paths to read.
  @Test func nonTransportFetchErrorsPassThrough() async throws {
    await withDependencies {
      $0.fetch = failing(FetchError.bodyAlreadyConsumed)
    } operation: {
      await #expect(throws: FetchError.bodyAlreadyConsumed) {
        try await ChatGPTAuth.refresh(tokens)
      }
    }
  }

  @Test func unreachableDescriptionCarriesHopAndKind() {
    let error = ChatGPTAuthError.unreachable(
      hop: "auth.openai.com to refresh ChatGPT credentials",
      kind: .connectTimeout,
    )
    #expect(error.description == "could not reach auth.openai.com to refresh ChatGPT credentials: connectTimeout")
  }
}
