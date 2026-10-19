/// How long exec and run_script let their work live, in seconds. These are
/// policy, kept together because the values may change.
public enum ToolLifetimes {
  /// exec's `max_lifetime_seconds` when a call names none. Task-local only so
  /// tests can shorten it.
  @TaskLocal static var execDefault: Double = 1800
  /// exec's and run_script's `wait_seconds` when a call names none: how long
  /// the call waits before it returns `running`. Task-local only so tests can
  /// shorten it.
  @TaskLocal public static var waitDefault: Double = 300
  /// How far past its lifetime an exec call still waits, so the lifetime's
  /// kill comes back as the result rather than as `running`.
  public static let lifetimeSlack: Double = 10
  /// run_script's `max_lifetime_seconds` when a call names none.
  public static let scriptDefault: Double = 3600
  /// The longest `max_lifetime_seconds` exec or run_script accepts. A larger
  /// one is refused, never clamped.
  public static let ceiling: Double = 14400
}
