import Fetch
import Foundation
import HTTPTypes
import ServeTesting
import SpaceCore
import SpaceServer
import Testing
import WebBundle

@Suite struct WebBundleTests {
  private func client() throws -> FetchClient {
    let space = try Space.inMemory()
    return ServeTesting.client(upgrading: SpaceServer.handler(
      space: space, hub: MachineHub(space: space), dev: true, webContent: try WebBundle.load(),
    ))
  }

  @Test func shellSDKIsBundledNoCacheAndHeadHasTheServedLength() async throws {
    let web = try client()
    let script = try await web(Request(url: URL(string: "https://shared.localhost/_/shell.js")!))
    #expect(script.status == .ok)
    #expect(script.headers[.contentType] == "text/javascript; charset=utf-8")
    #expect(script.headers[.cacheControl] == "no-cache")
    let body = try await script.text()
    #expect(body.contains("export const context"))
    #expect(body.contains("export function interceptedNavigation"))
    #expect(body.contains("wuhu:ready"))
    #expect(body.contains("wuhu:context"))
    #expect(body.contains("wuhu:navigate"))
    // One served file carries both shell transports; a native app that had to
    // ship its own copy would be a second contract.
    #expect(body.contains("parent.postMessage"))
    #expect(body.contains("messageHandlers?.wuhuShell"))
    #expect(body.contains("--wuhu-inset-${edge}"))

    let head = try await web(Request(url: URL(string: "https://shared.localhost/_/shell.js")!, method: .head))
    #expect(head.status == .ok)
    #expect(head.headers[.contentLength] == String(body.utf8.count))
    #expect(head.headers[.cacheControl] == "no-cache")
    #expect(try await head.text() == "")
  }

  @Test func thePageWorkerAndItsModulesAreServedNoCacheWithRootScope() async throws {
    let web = try client()
    let worker = try await web(Request(url: URL(string: "https://shared.localhost/_/worker.js")!))
    #expect(worker.status == .ok)
    #expect(worker.headers[.contentType] == "text/javascript; charset=utf-8")
    #expect(worker.headers[.cacheControl] == "no-cache")
    #expect(worker.headers[HTTPField.Name("Service-Worker-Allowed")!] == "/")
    #expect(try await worker.text().contains("export function pageWorker"))

    let space = try await web(Request(url: URL(string: "https://shared.localhost/_/space-core.js")!))
    #expect(space.status == .ok)
    #expect(space.headers[.cacheControl] == "no-cache")
    #expect(try await space.text().contains("export function createSpace"))

    let module = try await web(Request(url: URL(string: "https://shared.localhost/_/open-cache.js")!))
    #expect(module.status == .ok)
    #expect(module.headers[.cacheControl] == "no-cache")
    #expect(module.headers[HTTPField.Name("Service-Worker-Allowed")!] == nil)
    #expect(try await web(Request(url: URL(string: "https://shared.localhost/_/open-cache.d.ts")!)).status == .notFound)
  }
}
