import ComposableArchitecture
import Dependencies
import Foundation
import PiAI
import WuhuClient

struct AppSettingsClient: Sendable {
  var load: @Sendable () -> AppSettings
  var save: @Sendable (AppSettings) -> Void
}

extension AppSettingsClient: DependencyKey {
  static let liveValue = AppSettingsClient(
    load: {
      let defaults = UserDefaults.standard
      let key = "wuhu.app.settings"
      guard let data = defaults.data(forKey: key) else { return AppSettings.defaults() }
      do {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        return decoded.servers.isEmpty ? AppSettings.defaults() : decoded
      } catch {
        return AppSettings.defaults()
      }
    },
    save: { settings in
      let defaults = UserDefaults.standard
      let key = "wuhu.app.settings"
      guard let data = try? JSONEncoder().encode(settings) else { return }
      defaults.set(data, forKey: key)
    },
  )
}

extension AppSettingsClient: TestDependencyKey {
  static let testValue = AppSettingsClient(
    load: { AppSettings.defaults() },
    save: { _ in },
  )
}

extension DependencyValues {
  var appSettingsClient: AppSettingsClient {
    get { self[AppSettingsClient.self] }
    set { self[AppSettingsClient.self] = newValue }
  }
}

struct WuhuClientProvider: Sendable {
  var make: @Sendable (URL) -> WuhuClient
}

extension WuhuClientProvider: DependencyKey {
  static let liveValue = WuhuClientProvider(
    make: { baseURL in
      WuhuClient(baseURL: baseURL)
    },
  )
}

extension WuhuClientProvider: TestDependencyKey {
  static let testValue = WuhuClientProvider(
    make: { baseURL in
      WuhuClient(baseURL: baseURL, http: WuhuAppTestHTTPClient())
    },
  )
}

extension DependencyValues {
  var wuhuClientProvider: WuhuClientProvider {
    get { self[WuhuClientProvider.self] }
    set { self[WuhuClientProvider.self] = newValue }
  }
}

private struct WuhuAppTestHTTPClient: HTTPClient {
  func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    guard request.method == "GET" else {
      throw PiAIError.unsupported("WuhuAppTestHTTPClient only supports GET")
    }
    return (Data("[]".utf8), HTTPResponse(statusCode: 200, headers: [:]))
  }

  func sse(for _: HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.init(data: #"{"type":"done"}"#))
      continuation.finish()
    }
  }
}
