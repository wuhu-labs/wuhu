import Foundation
import Hummingbird

struct WuhuRequestContext: RequestContext {
  var coreContext: CoreRequestContextStorage

  init(source: Source) {
    coreContext = .init(source: source)
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
