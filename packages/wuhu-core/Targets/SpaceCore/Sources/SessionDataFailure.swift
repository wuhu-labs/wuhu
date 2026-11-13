#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

public func isUnreadableSessionData(_ error: any Error) -> Bool {
  error is DecodingError || error is ExecutorSpecError || (error as? CocoaError)?.code == .formatting
}
