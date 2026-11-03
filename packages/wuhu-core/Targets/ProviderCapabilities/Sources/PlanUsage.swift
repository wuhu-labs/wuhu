import JSONValue
import struct SpaceContract.UsageWindow

public enum PlanUsage {
  private static func windowName(minutes: Int) -> String {
    switch minutes {
    case 300: "five_hour"
    case 10080: "seven_day"
    default: "\(minutes)_minute"
    }
  }

  // A plan with one window still sends the other family, zero minutes long.
  public static func codex(headers: [String: String]) -> [UsageWindow] {
    [("x-codex-primary", "primary"), ("x-codex-secondary", "secondary")].compactMap { prefix, fallback in
      let usedPercent = headers["\(prefix)-used-percent"].flatMap(Double.init)
      let resetsAt = headers["\(prefix)-reset-at"].flatMap(Double.init)
      let minutes = headers["\(prefix)-window-minutes"].flatMap(Int.init)
      guard usedPercent != nil || resetsAt != nil, minutes != 0 else { return nil }
      return UsageWindow(name: minutes.map(windowName(minutes:)) ?? fallback, usedPercent: usedPercent, resetsAt: resetsAt, windowMinutes: minutes)
    }
  }

  // The ChatGPT backend's own usage read, the one Codex's /status makes.
  public static func codex(payload: JSONValue) -> (plan: String?, windows: [UsageWindow]) {
    let limit = payload.object?["rate_limit"]?.object
    let windows = ["primary_window", "secondary_window"].compactMap { key -> UsageWindow? in
      guard let window = limit?[key]?.object else { return nil }
      let seconds = window["limit_window_seconds"]?.intValue
      return UsageWindow(
        name: seconds.map { windowName(minutes: $0 / 60) } ?? key,
        usedPercent: window["used_percent"]?.doubleValue,
        resetsAt: window["reset_at"]?.doubleValue,
        windowMinutes: seconds.map { $0 / 60 },
      )
    }
    return (payload.object?["plan_type"]?.stringValue, windows)
  }

  public static func codexSocket(_ payload: JSONValue) -> (plan: String?, windows: [UsageWindow]) {
    let rates = payload.object?["rate_limits"]?.object
    var windows: [String: UsageWindow] = [:]
    func record(_ name: String, _ value: JSONValue) {
      guard let window = value.object, let minutes = window["window_minutes"]?.intValue, minutes > 0,
            let used = window["used_percent"]?.doubleValue, used.isFinite, (0 ... 100).contains(used),
            let reset = window["reset_at"]?.doubleValue, reset.isFinite, reset >= 0 else { return }
      windows[name] = UsageWindow(name: name, usedPercent: used, resetsAt: reset, windowMinutes: minutes)
    }
    for key in ["primary", "secondary"] {
      if let value = rates?[key], let minutes = value.object?["window_minutes"]?.intValue {
        record(windowName(minutes: minutes), value)
      }
    }
    for (name, value) in rates?["windows"]?.object ?? [:] { record(name, value) }
    return (payload.object?["plan_type"]?.stringValue, windows.values.sorted { $0.name < $1.name })
  }
}
