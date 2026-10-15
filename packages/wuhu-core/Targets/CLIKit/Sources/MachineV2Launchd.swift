#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies

struct MachineV2Launchd {
  let userID: UInt32
  let command: @Sendable ([String]) async throws -> String
  var domain: String { "gui/\(self.userID)" }

  func bootout(_ service: String) async throws {
    do { _ = try await command(["/bin/launchctl", "bootout", service]) }
    catch {
      let diagnostic = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
      guard diagnostic.hasSuffix("Could not find specified service") || diagnostic.hasSuffix("Boot-out failed: 3: No such process") else {
        throw MachineV2InstallError(code: .serviceFailure, message: "launchctl bootout \(service): \(error); service unload was not confirmed; inspect with: launchctl print \(service)")
      }
    }
    @Dependency(\.continuousClock) var clock
    try await self.waitForUnload(service, clock: clock)
  }

  private func waitForUnload<C: Clock>(_ service: String, clock: C) async throws where C.Duration == Duration {
    let deadline = clock.now.advanced(by: .seconds(10))
    for attempt in 0 ... 100 {
      if attempt > 0, clock.now >= deadline { break }
      do { if try await !self.isLoaded(service) { return } }
      catch { throw MachineV2InstallError(code: .serviceFailure, message: "cannot confirm unload of \(service): \(error); service state is unknown; inspect with: launchctl print \(service)") }
      let remaining = clock.now.duration(to: deadline)
      if attempt < 100 && remaining > .zero { try await clock.sleep(for: min(.milliseconds(100), remaining)) }
    }
    throw MachineV2InstallError(code: .serviceFailure, message: "launchctl bootout did not unload \(service) within 10 seconds; service is still loaded; inspect with: launchctl print \(service); retry the machine-v2 operation after it exits")
  }

  func bootstrap(label: String, plist: URL, recovery: String? = nil) async throws {
    @Dependency(\.continuousClock) var clock
    let arguments = ["/bin/launchctl", "bootstrap", domain, plist.path]
    for attempt in 0 ... 4 {
      do { _ = try await command(arguments); return }
      catch {
        if let failure = error as? CommandFailure, failure.status == 5, attempt < 4 {
          try await clock.sleep(for: .milliseconds(250 * (1 << attempt)))
          continue
        }
        let service = domain + "/" + label
        let state: String
        do { state = try await self.isLoaded(service) ? "service is still loaded" : "service was left unloaded" }
        catch { state = "service state is unknown (launchctl print failed: \(error))" }
        let quoted = "'" + plist.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let recover = recovery ?? "launchctl bootstrap \(domain) \(quoted)"
        throw MachineV2InstallError(code: .serviceFailure, message: "launchctl bootstrap failed after \(attempt + 1) attempt(s): \(error); \(state); inspect with: launchctl print \(service); recover with: \(recover)")
      }
    }
  }

  private func isLoaded(_ service: String) async throws -> Bool {
    do { _ = try await command(["/bin/launchctl", "print", service]); return true }
    catch let error as CommandFailure where error.status == 113 && error.stderr.contains("Could not find service") { return false }
  }
}
