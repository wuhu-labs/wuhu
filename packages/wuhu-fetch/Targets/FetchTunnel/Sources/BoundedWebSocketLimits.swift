public struct BoundedWebSocketLimits: Sendable, Equatable {
  public var messageBytes: Int
  public var bufferedReceiveBytes: Int

  public init(messageBytes: Int = 64 << 10, bufferedReceiveBytes: Int = 1 << 20) {
    self.messageBytes = messageBytes
    self.bufferedReceiveBytes = bufferedReceiveBytes
  }

  public func validate() throws {
    guard messageBytes > 0, messageBytes <= 64 << 20, bufferedReceiveBytes > 0, bufferedReceiveBytes <= 64 << 20 else {
      throw TunnelError.invalidConfiguration
    }
  }
}
