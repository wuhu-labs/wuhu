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
import enum ExecSupervisor.ExecSupervisor
import struct Fetch.FetchClient
import FetchAsyncHTTPClient
import FetchWebSocket
import Logging
import enum PinnedTLS.PinnedTLS
import enum PinnedTLS.SystemTrust
import SessionTools
import enum SpaceCore.UserRecovery
import SpaceServer
import TaskLifetime
import enum WebBundle.WebBundle

struct StandardInputEncodingError: Error, CustomStringConvertible {
  var description: String { "stdin is not valid UTF-8" }
}

@available(macOS 10.15, *)
@main
enum Main {
  static func main() async {
    if CommandLine.arguments.count >= 5, Array(CommandLine.arguments[1 ... 2]) == ["machine-v2", "exec-child"] {
      ExecSupervisor.runChild(Array(CommandLine.arguments.dropFirst(3)))
    }
    if CommandLine.arguments.count == 6, Array(CommandLine.arguments[1 ... 2]) == ["machine-v2", "local-agent"] {
      do {
        try await ExecSupervisor.runLocalAgent(machine: CommandLine.arguments[3], operationsDirectory: CommandLine.arguments[4], socket: CommandLine.arguments[5], executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
        exit(0)
      } catch { FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8)); exit(1) }
    }
    if CommandLine.arguments.count == 4, Array(CommandLine.arguments[1 ... 2]) == ["machine-v2", "supervise"] {
      do { try await ExecSupervisor.run(directory: CommandLine.arguments[3]); exit(0) }
      catch { FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8)); exit(1) }
    }
    if CommandLine.arguments.count == 4, Array(CommandLine.arguments[1 ... 2]) == ["machine-v2", "exec-worker"] {
      do { try await ExecSupervisor.runWorker(directory: CommandLine.arguments[3]); exit(0) }
      catch { FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8)); exit(1) }
    }
    if CommandLine.arguments.dropFirst() == ["--version"] {
      print("wuhu \(BuildStamp.version) (\(BuildStamp.commit), \(BuildStamp.date))")
      exit(0)
    }
    // Diagnostics belong on stderr: exec stdout must stay pipe-clean, and the
    // machine agent's foreground logs must not mix into piped output.
    LoggingSystem.bootstrap({ label, metadataProvider in
      StreamLogHandler.standardError(label: label, metadataProvider: metadataProvider)
    }, metadataProvider: SpaceLogContext.metadataProvider)
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
    // A script's identity fetch answers redirects itself, so its hops go out
    // on a client that follows none.
    var hopConfiguration = HTTPClient.Configuration()
    hopConfiguration.redirectConfiguration = .disallow
    let hopClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: hopConfiguration)
    prepareDependencies {
      $0.fetch = .asyncHTTPClient(inferenceClient, timeout: nil)
      $0.scriptHop = .asyncHTTPClient(hopClient, timeout: nil)
      $0[WebSocketConnector.self] = .live
      $0[ServerTrustProbe.self] = ServerTrustProbe(
        validateSystem: { host, port in
          try await SystemTrust.validate(host: host, port: port, anchors: .platformDefault)
        },
        observeLeaf: { host, port in try await PinnedTLS.probeCertificate(host: host, port: port) },
      )
      $0[UpgradeEnvironment.self] = .live
    }
    // A worker main started: it serves main until main shuts it down.
    if ProcessInfo.processInfo.environment[WorkerProcess.roleVariable] == WorkerProcess.role {
      let code = await WorkerProcess.run(environment: ProcessInfo.processInfo.environment)
      for shutdown in [inferenceClient.shutdown, client.shutdown, hopClient.shutdown] { try? await shutdown() }
      exit(code)
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
    let rootScope = TaskScope()
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
        // With its workers out of process, SIGHUP reboots main in place.
        let (reboots, reboot) = AsyncStream<Void>.makeStream()
        let server = try rootScope.run("space-server") {
          try await SpaceServer.serve(
            folder: URL(fileURLWithPath: config.folder, isDirectory: true),
            host: config.host,
            port: config.port,
            origin: config.origin.flatMap(URL.init(string:)),
            dev: config.dev,
            version: BuildStamp.version,
            publicRead: config.publicRead,
            devImport: config.devImport.map { URL(fileURLWithPath: $0, isDirectory: true) },
            devExport: config.devExport.map { URL(fileURLWithPath: $0, isDirectory: true) },
            certificate: config.certificate.map { URL(fileURLWithPath: $0) },
            privateKey: config.privateKey.map { URL(fileURLWithPath: $0) },
            contentHostPattern: config.contentHostPattern,
            aiDisclosureFile: config.aiDisclosure.map { URL(fileURLWithPath: $0) },
            groupCertificate: config.groupCertificate.map { URL(fileURLWithPath: $0) },
            groupPrivateKey: config.groupPrivateKey.map { URL(fileURLWithPath: $0) },
            webAppDirectory: config.webApp.map { URL(fileURLWithPath: $0, isDirectory: true) },
            webContent: try WebBundle.load(),
            telemetryEnvironment: ProcessInfo.processInfo.environment,
            workers: config.workerProcess ? .process(reboots: reboots) : .inProcess,
          )
        }
        let sources = [SIGINT, SIGTERM].map { number in
          signal(number, SIG_IGN)
          let source = DispatchSource.makeSignalSource(signal: number)
          source.setEventHandler { server.cancel() }
          source.resume()
          return source
        }
        var hangup: DispatchSourceSignal?
        if config.workerProcess {
          signal(SIGHUP, SIG_IGN)
          let source = DispatchSource.makeSignalSource(signal: SIGHUP)
          source.setEventHandler { reboot.yield() }
          source.resume()
          hangup = source
        }
        defer {
          sources.forEach { $0.cancel() }
          hangup?.cancel()
        }
        if case let .reboot(handover) = try await server.value {
          let failure = handover.exec()
          FileHandle.standardError.write(Data("could not re-execute wuhu serve: \(String(cString: strerror(failure)))\n".utf8))
          exit(1)
        }
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
      machineV2ServiceCommand: { try await capturedProcessOutput($0) },
    )
    let code: Int32
    do {
      if try await MachineV2Runtime.command(arguments: Array(CommandLine.arguments.dropFirst()), environment: runner.environment, fetch: .asyncHTTPClient(client, timeout: .seconds(5)), stdin: runner.stdin, stdout: runner.stdout, version: BuildStamp.version, serviceCommand: { try await capturedProcessOutput($0) }) { code = 0 }
      else { code = await runner.run(arguments: Array(CommandLine.arguments.dropFirst())) }
    } catch {
      FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8)); code = MachineV2Runtime.exitStatus(for: error)
    }
    var shutdownFailed = false
    await rootScope.close()
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
