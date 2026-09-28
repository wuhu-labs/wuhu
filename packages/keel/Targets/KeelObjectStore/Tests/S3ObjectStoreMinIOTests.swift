import AsyncHTTPClient
import Fetch
import FetchAsyncHTTPClient
import Foundation
import KeelObjectStore
import Testing

// Opt-in only: skipped in CI. Point it at a local MinIO (path-style) with, e.g.
//   docker run -p 9000:9000 -e MINIO_ROOT_USER=minioadmin \
//     -e MINIO_ROOT_PASSWORD=minioadmin minio/minio server /data
//   mc mb local/keel-test
// then export KEEL_S3_ENDPOINT/KEEL_S3_BUCKET/KEEL_S3_ACCESS_KEY/KEEL_S3_SECRET_KEY.
private enum MinIO {
  static let environment = ProcessInfo.processInfo.environment

  static var configuration: S3Configuration? {
    guard let endpoint = environment["KEEL_S3_ENDPOINT"].flatMap(URL.init(string:)),
          let bucket = environment["KEEL_S3_BUCKET"],
          let access = environment["KEEL_S3_ACCESS_KEY"],
          let secret = environment["KEEL_S3_SECRET_KEY"]
    else { return nil }
    let addressing: S3Configuration.Addressing =
      environment["KEEL_S3_ADDRESSING"] == "virtual" ? .virtualHost : .pathStyle
    return S3Configuration(
      endpoint: endpoint,
      region: environment["KEEL_S3_REGION"] ?? "us-east-1",
      bucket: bucket,
      addressing: addressing,
      credentials: SigV4Credentials(accessKeyID: access, secretAccessKey: secret),
    )
  }

  static var isConfigured: Bool { configuration != nil }
}

@Suite(.enabled(if: MinIO.isConfigured))
struct S3ObjectStoreMinIOContractTests {
  private func contract() throws -> ObjectStoreContract {
    let configuration = try #require(MinIO.configuration)
    let client = FetchClient.asyncHTTPClient(HTTPClient.shared)
    return ObjectStoreContract(capabilities: .init(preservesContentType: true)) {
      S3ObjectStore(configuration: configuration, fetch: client)
    }
  }

  @Test func putGetRoundTrip() async throws { try await self.contract().putGetRoundTrip() }
  @Test func overwrite() async throws { try await self.contract().overwrite() }
  @Test func deleteIdempotence() async throws { try await self.contract().deleteIdempotence() }
  @Test func missingKeyError() async throws { try await self.contract().missingKeyError() }
  @Test func existence() async throws { try await self.contract().existence() }
  @Test func listOrderingAndPagination() async throws { try await self.contract().listOrderingAndPagination() }
}
