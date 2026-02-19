import Foundation
import PiAI
import PiAgent

actor WuhuSessionRuntimeConfig {
  private var _tools: [AnyAgentTool] = []
  private var _streamFn: StreamFn = PiAI.streamSimple
  private var _contextActor: WuhuAgentsContextActor?

  func setTools(_ tools: [AnyAgentTool]) {
    _tools = tools
  }

  func tools() -> [AnyAgentTool] {
    _tools
  }

  func setStreamFn(_ streamFn: @escaping StreamFn) {
    _streamFn = streamFn
  }

  func streamFn() -> StreamFn {
    _streamFn
  }

  func setContextActor(_ actor: WuhuAgentsContextActor?) {
    _contextActor = actor
  }

  func contextSection() async -> String {
    guard let actor = _contextActor else { return "" }
    return await actor.contextSection()
  }
}

