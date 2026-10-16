/// How long exec and run_script let their work live, in seconds. These are
/// policy, kept together because the values may change.
enum ToolLifetimes {
  /// exec's `max_lifetime_seconds` when a call names none. Task-local only so
  /// tests can shorten it.
  @TaskLocal static var execDefault: Double = 1800
  /// run_script's `max_lifetime_seconds` when a call names none.
  static let scriptDefault: Double = 3600
  /// The longest `max_lifetime_seconds` exec or run_script accepts. A larger
  /// one is refused, never clamped.
  static let ceiling: Double = 14400
}
