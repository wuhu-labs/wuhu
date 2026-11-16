import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct IntegrationServerConfiguration: Sendable {
  public var pythonExecutable: String
  public var startupTimeout: TimeInterval

  public init(
    pythonExecutable: String = ProcessInfo.processInfo.environment["FETCH_TEST_PYTHON"] ?? "python3",
    startupTimeout: TimeInterval = 5,
  ) {
    self.pythonExecutable = pythonExecutable
    self.startupTimeout = startupTimeout
  }
}

public final class IntegrationServer {
  public let baseURL: URL

  private let process: Process
  private let portFileURL: URL

  private init(baseURL: URL, process: Process, portFileURL: URL) {
    self.baseURL = baseURL
    self.process = process
    self.portFileURL = portFileURL
  }

  deinit {
    self.stop()
  }

  public static func start(
    configuration: IntegrationServerConfiguration = .init(),
  ) throws -> Self {
    #if WUHU_EMBEDDED
      // A Bazel test assembles no dependency's resource bundle; the script's bytes ride in the binary.
      let scriptArguments = [configuration.pythonExecutable, "-c", integrationServerScript]
    #else
      guard let script = Bundle.module.url(forResource: "integration_server", withExtension: "py") else {
        throw IntegrationServerError.missingScript
      }
      let scriptArguments = [configuration.pythonExecutable, script.path]
    #endif

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

    let portFileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("port")

    process.arguments = scriptArguments + [
      "--port-file",
      portFileURL.path,
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()

    let deadline = Date().addingTimeInterval(configuration.startupTimeout)
    while Date() < deadline {
      if let contents = try? String(contentsOf: portFileURL, encoding: .utf8),
         let port = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return Self(
          baseURL: URL(string: "http://127.0.0.1:\(port)")!,
          process: process,
          portFileURL: portFileURL,
        )
      }

      if !process.isRunning {
        throw IntegrationServerError.serverExitedEarly
      }

      Thread.sleep(forTimeInterval: 0.05)
    }

    process.terminate()
    throw IntegrationServerError.startupTimedOut
  }

  public func stop() {
    if self.process.isRunning {
      self.process.terminate()

      let deadline = Date().addingTimeInterval(1)
      while self.process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }

      if self.process.isRunning {
        self.process.interrupt()
      }

      let interruptDeadline = Date().addingTimeInterval(1)
      while self.process.isRunning, Date() < interruptDeadline {
        Thread.sleep(forTimeInterval: 0.05)
      }

      if self.process.isRunning {
        kill(self.process.processIdentifier, SIGKILL)
        self.process.waitUntilExit()
      }
    }
    try? FileManager.default.removeItem(at: self.portFileURL)
  }
}

public enum IntegrationServerError: Error, Sendable {
  case startupTimedOut
  case serverExitedEarly
  case missingScript
}

#if WUHU_EMBEDDED
  private let integrationServerScript = EmbeddedIntegrationServer.text(for: EmbeddedIntegrationServer.files.first { $0.path == ["integration_server.py"] }!)
#endif
