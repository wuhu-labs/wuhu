import Foundation
import Hummingbird
import HummingbirdWebSocket

struct WuhuRequestContext: RequestContext, WebSocketRequestContext {
  var coreContext: CoreRequestContextStorage
  let webSocket: WebSocketHandlerReference<Self>

  init(source: Source) {
    coreContext = .init(source: source)
    webSocket = .init()
  }

  var requestDecoder: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .secondsSince1970
    return d
  }

  var responseEncoder: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    e.dateEncodingStrategy = .secondsSince1970
    return e
  }
}
