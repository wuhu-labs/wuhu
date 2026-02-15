import Foundation
import PiAgent
import PiAI

actor WuhuSessionAgentActor {
  struct PreparedPrompt: Sendable {
    var renderedInput: String
    var systemPrompt: String
    var model: Model
    var tools: [AnyAgentTool]
    var messages: [Message]
    var requestOptions: RequestOptions
    var streamFn: StreamFn
  }

  let sessionID: String
  private weak var service: WuhuService?

  private var agent: PiAgent.Agent?
  private var eventsConsumerTask: Task<Void, Never>?

  private var runningPromptTask: Task<Void, Never>?

  private let runEndStream: AsyncStream<Void>
  private let runEndContinuation: AsyncStream<Void>.Continuation

  init(sessionID: String, service: WuhuService) {
    self.sessionID = sessionID
    self.service = service

    let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    runEndStream = stream
    runEndContinuation = continuation
  }

  deinit {
    runningPromptTask?.cancel()
    eventsConsumerTask?.cancel()
  }

  func abort() async {
    runningPromptTask?.cancel()
    runningPromptTask = nil
    if let agent {
      await agent.abort()
    }
  }

  func isIdle() -> Bool {
    runningPromptTask == nil
  }

  func steerUser(_ text: String, timestamp: Date) async {
    guard let agent else { return }
    await agent.steer(.user(text, timestamp: timestamp))
  }

  func runDetached(_ prepared: PreparedPrompt) async throws {
    if runningPromptTask != nil {
      throw PiAIError.unsupported("Session is already executing")
    }

    let agent = try await ensureAgent(prepared: prepared)
    ensureEventConsumer(agent: agent)

    runningPromptTask = Task { [weak self] in
      guard let self else { return }
      defer { Task { await self.clearRunningTask() } }

      var promptSucceeded = false
      do {
        try await agent.prompt(prepared.renderedInput)
        promptSucceeded = true
      } catch {
        await agent.abort()
      }

      if promptSucceeded {
        let idleTimeoutTask = Task {
          try? await Task.sleep(nanoseconds: 10_000_000_000)
          await agent.abort()
        }
        await agent.waitForIdle()
        idleTimeoutTask.cancel()
      }

      await self.waitForRunEnd(timeoutNanoseconds: 5_000_000_000)
      await service?.sessionDidBecomeIdle(sessionID: sessionID)
    }
  }

  private func clearRunningTask() {
    runningPromptTask = nil
  }

  private func waitForRunEnd(timeoutNanoseconds: UInt64) async {
    let waitTask = Task { [runEndStream] in
      var iterator = runEndStream.makeAsyncIterator()
      _ = await iterator.next()
    }
    let timeoutTask = Task {
      try? await Task.sleep(nanoseconds: timeoutNanoseconds)
      waitTask.cancel()
    }
    _ = await waitTask.value
    timeoutTask.cancel()
  }

  private func ensureAgent(prepared: PreparedPrompt) async throws -> PiAgent.Agent {
    if let agent {
      await agent.setSystemPrompt(prepared.systemPrompt)
      await agent.setModel(prepared.model)
      await agent.setTools(prepared.tools)
      await agent.setRequestOptions(prepared.requestOptions)
      await agent.replaceMessages(prepared.messages)
      return agent
    }

    let agent = PiAgent.Agent(opts: .init(
      initialState: .init(
        systemPrompt: prepared.systemPrompt,
        model: prepared.model,
        tools: prepared.tools,
        messages: prepared.messages,
      ),
      requestOptions: prepared.requestOptions,
      streamFn: prepared.streamFn,
    ))
    self.agent = agent
    return agent
  }

  private func ensureEventConsumer(agent: PiAgent.Agent) {
    guard eventsConsumerTask == nil else { return }

    let sessionID = sessionID
    let runEndContinuation = runEndContinuation

    eventsConsumerTask = Task { [weak service] in
      guard let service else { return }
      do {
        for try await event in agent.events {
          do {
            try await service.handleAgentEvent(event, sessionID: sessionID)
          } catch {
            // Best-effort: ignore handler errors for long-lived session agents.
          }
          if case .agentEnd = event {
            runEndContinuation.yield(())
          }
        }
      } catch {
        // Best-effort: ignore stream termination errors.
      }
    }
  }
}
