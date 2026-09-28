#if canImport(FoundationEssentials)
  // The existing CLI stdio uses FileHandle, which is not in FoundationEssentials.
  import class Foundation.FileHandle
  import FoundationEssentials
#else
  import Foundation
#endif

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

import AsyncHTTPClient
import CLIKit
import Dependencies
import Dispatch
import struct Fetch.FetchClient
import FetchAsyncHTTPClient
import Logging
import enum PinnedTLS.PinnedTLS
import enum PinnedTLS.SystemTrust
import enum SpaceCore.UserRecovery
import SpaceServer

struct StandardInputEncodingError: Error, CustomStringConvertible {
  var description: String { "stdin is not valid UTF-8" }
}

@available(macOS 10.15, *)
@main
enum Main {
  static func main() async {
    if CommandLine.arguments.dropFirst() == ["--version"] {
      print("wuhu \(BuildStamp.version) (\(BuildStamp.commit), \(BuildStamp.date))")
      exit(0)
    }
    // Diagnostics belong on stderr: exec stdout must stay pipe-clean, and the
    // machine agent's foreground logs must not mix into piped output.
    LoggingSystem.bootstrap { label in
      StreamLogHandler.standardError(label: label)
    }
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    var inferenceConfiguration = HTTPClient.Configuration()
    inferenceConfiguration.enableHTTP2HealthChecks()
    let inferenceClient = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: inferenceConfiguration,
    )
    // Server-side inference reaches the network through the ambient fetch
    // dependency, whose live default is unimplemented on purpose; the process
    // binds the real transport once here.
    prepareDependencies {
      $0.fetch = .asyncHTTPClient(inferenceClient, timeout: nil)
      $0[ServerTrustProbe.self] = ServerTrustProbe(
        validateSystem: { host, port in
          try await SystemTrust.validate(host: host, port: port, anchors: .platformDefault)
        },
        observeLeaf: { host, port in try await PinnedTLS.probeCertificate(host: host, port: port) },
      )
      $0[UpgradeEnvironment.self] = .live
    }
    // Space traffic dials pin-mode when the user store has a recorded pin and
    // system-PKI mode otherwise; nothing is recorded outside wuhu use/trust.
    let trust: ServerTrust
    do {
      trust = try ServerTrust(environment: ProcessInfo.processInfo.environment)
    } catch {
      FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
      exit(1)
    }
    let runner = CommandRunner(
      fetch: SpaceTransport.diagnosing(
        SpaceTransport.fetchClient(trust: trust, timeout: .seconds(30), plain: .asyncHTTPClient(client)),
        trust: trust,
      ),
      observeFetch: SpaceTransport.diagnosing(
        SpaceTransport.fetchClient(trust: trust, timeout: nil, plain: .asyncHTTPClient(client, timeout: nil)),
        trust: trust,
      ),
      serve: { config in
        let server = Task {
          try await SpaceServer.serve(
            folder: URL(fileURLWithPath: config.folder, isDirectory: true),
            host: config.host,
            port: config.port,
            origin: config.origin.flatMap(URL.init(string:)),
            webPort: config.webPort,
            webOrigin: config.webOrigin.flatMap(URL.init(string:)),
            dev: config.dev,
            version: BuildStamp.version,
            publicRead: config.publicRead,
            devImport: config.devImport.map { URL(fileURLWithPath: $0, isDirectory: true) },
            devExport: config.devExport.map { URL(fileURLWithPath: $0, isDirectory: true) },
            certificate: config.certificate.map { URL(fileURLWithPath: $0) },
            privateKey: config.privateKey.map { URL(fileURLWithPath: $0) },
            groupCertificate: config.groupCertificate.map { URL(fileURLWithPath: $0) },
            groupPrivateKey: config.groupPrivateKey.map { URL(fileURLWithPath: $0) },
            webAppDirectory: config.webApp.map { URL(fileURLWithPath: $0, isDirectory: true) },
          )
        }
        let sources = [SIGINT, SIGTERM].map { number in
          signal(number, SIG_IGN)
          let source = DispatchSource.makeSignalSource(signal: number)
          source.setEventHandler { server.cancel() }
          source.resume()
          return source
        }
        defer { sources.forEach { $0.cancel() } }
        try await server.value
      },
      user: { command in
        switch command {
        case let .add(folder, name, admin):
          (try await UserRecovery.add(folder: URL(fileURLWithPath: folder, isDirectory: true), name: name, admin: admin), nil)
        case let .reset(folder, account):
          (try await UserRecovery.reset(folder: URL(fileURLWithPath: folder, isDirectory: true), account: account), nil)
        case let .invite(folder, account, server, ttl):
          try await UserRecovery.invite(
            folder: URL(fileURLWithPath: folder, isDirectory: true),
            account: account,
            server: server,
            ttl: ttl.map(TimeInterval.init),
          )
        }
      },
      stdin: {
        let data = isatty(0) == 1 ? FileHandle.standardInput.availableData : FileHandle.standardInput.readDataToEndOfFile()
        guard let string = String(data: data, encoding: .utf8) else {
          throw StandardInputEncodingError()
        }
        return string
      },
      stdout: { text in
        FileHandle.standardOutput.write(Data(text.utf8))
      },
      stderr: { text in
        FileHandle.standardError.write(Data(text.utf8))
      },
      stdinIsTerminal: isatty(0) == 1,
      stdinChunks: {
        AsyncStream(unfolding: {
          let data = FileHandle.standardInput.availableData
          return data.isEmpty ? nil : Array(data)
        })
      },
      stdoutBytes: { bytes in
        FileHandle.standardOutput.write(Data(bytes))
      },
      stderrBytes: { bytes in
        FileHandle.standardError.write(Data(bytes))
      },
      dial: SpaceTransport.webSocketTransport(trust: trust, maxFrameBytes: MachineHub.maximumFrameBytes),
      environment: ProcessInfo.processInfo.environment,
      currentDirectory: FileManager.default.currentDirectoryPath,
      version: BuildStamp.version,
    )
    let code = await runner.run(arguments: Array(CommandLine.arguments.dropFirst()))
    var shutdownFailed = false
    for shutdown in [inferenceClient.shutdown, client.shutdown] {
      do {
        try await shutdown()
      } catch {
        shutdownFailed = true
        FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
      }
    }
    exit(shutdownFailed ? 1 : code)
  }
}
