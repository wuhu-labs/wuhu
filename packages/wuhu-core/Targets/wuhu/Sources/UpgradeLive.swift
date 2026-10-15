import AsyncHTTPClient
import CLIKit
import struct Fetch.FetchClient
import struct Fetch.Response
import FetchAsyncHTTPClient
import Foundation

extension UpgradeEnvironment {
  static var live: UpgradeEnvironment {
    UpgradeEnvironment(
      // Redirects stay disabled: the verb follows them itself so Authorization
      // never leaks to the pre-signed storage host (which rejects it).
      fetch: FetchClient { request in
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        do {
          let response = try await FetchClient.asyncHTTPClient(client, timeout: .minutes(10))(request)
          let data = try await response.data(upTo: 1 << 30)
          try await client.shutdown()
          return Response(status: response.status, headers: response.headers, body: .bytes(data))
        } catch {
          try? await client.shutdown()
          throw error
        }
      },
      extract: { archive, destination in
        #if os(macOS)
          _ = try await capturedProcessOutput(["/usr/bin/ditto", "-x", "-k", archive.path, destination.path])
        #else
          _ = try await capturedProcessOutput(["/usr/bin/env", "tar", "-xzf", archive.path, "-C", destination.path])
        #endif
      },
    )
  }
}
