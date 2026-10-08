import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging

enum OutboxDisposition: Sendable {
  case retry(Date)
  // Permanent for this one notification: advance the cursor and keep the
  // subscription. Never reported as a delivery.
  case skip
  case unsubscribe
}

struct OutboxDrain<Delivery: Sendable>: Sendable {
  var due: @Sendable (Date) async throws -> [Delivery]
  var deliver: @Sendable (Delivery) async throws -> Void
  var commit: @Sendable (Delivery) async throws -> Void
  var postpone: @Sendable (Delivery, Date) async throws -> Void
  var withdraw: @Sendable (Delivery) async throws -> Void
  var disposition: @Sendable (any Error, Delivery, Date) -> OutboxDisposition
  var changes: @Sendable () -> AsyncStream<Void>
  var describe: @Sendable (Delivery) -> Logger.MetadataValue
}

// One drain loop for every notification transport. Draining is serialized and
// coalescing: a second caller marks the run dirty rather than sending the same
// notification twice, which is the whole reason a transport does not own its
// own loop.
actor NotificationOutbox<Delivery: Sendable> {
  private let drain: OutboxDrain<Delivery>
  private let logger: Logger
  private var draining = false
  private var drainRequested = false
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.date) private var date

  init(_ drain: OutboxDrain<Delivery>, logger: Logger) {
    self.drain = drain
    self.logger = logger
  }

  func run() async {
    do {
      try await flush()
    } catch {
      logger.error("notification boot drain failed", metadata: ["error": "\(error)"])
    }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.observeChanges() }
      group.addTask { await self.pollRetries() }
      await group.waitForAll()
    }
  }

  func flush() async throws {
    if draining {
      drainRequested = true
      return
    }
    draining = true
    defer { draining = false }
    repeat {
      drainRequested = false
      try await flushAvailable()
    } while drainRequested
  }

  private func flushAvailable() async throws {
    while !Task.isCancelled {
      let deliveries = try await drain.due(date.now)
      guard !deliveries.isEmpty else { return }
      for delivery in deliveries {
        if Task.isCancelled { return }
        do {
          try await drain.deliver(delivery)
          try await drain.commit(delivery)
        } catch {
          switch drain.disposition(error, delivery, date.now) {
          case .unsubscribe:
            try await drain.withdraw(delivery)
          case .skip:
            logger.warning(
              "notification dropped",
              metadata: ["delivery": drain.describe(delivery), "error": "\(error)"],
            )
            try await drain.commit(delivery)
          case let .retry(retryAt):
            logger.warning(
              "notification deferred",
              metadata: ["delivery": drain.describe(delivery), "error": "\(error)"],
            )
            try await drain.postpone(delivery, retryAt)
          }
        }
      }
    }
  }

  private func observeChanges() async {
    for await _ in drain.changes() {
      if Task.isCancelled { return }
      do {
        try await flush()
      } catch {
        logger.error("notification change drain failed", metadata: ["error": "\(error)"])
      }
    }
  }

  private func pollRetries() async {
    while !Task.isCancelled {
      do {
        try await clock.sleep(for: .seconds(15))
        try await flush()
      } catch is CancellationError {
        return
      } catch {
        logger.error("notification retry drain failed", metadata: ["error": "\(error)"])
      }
    }
  }
}

func outboxRetryDate(header: String?, failures: Int, now: Date) -> Date {
  if let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
    return now.addingTimeInterval(seconds)
  }
  if let header {
    if let date = httpRetryDate(header) { return max(date, now) }
  }
  let seconds = min(3600, 5 * (1 << min(failures, 9)))
  return now.addingTimeInterval(TimeInterval(seconds))
}

private func httpRetryDate(_ header: String) -> Date? {
  let trailingWhitespace = header.reversed().prefix {
    $0.isWhitespace && !$0.isNewline
  }
  let trimmed = header.dropLast(trailingWhitespace.count)
  guard trimmed.hasSuffix("GMT") else { return nil }
  let fields = trimmed.split(whereSeparator: \.isWhitespace)
  guard fields.count == 6,
        [
          "mon,",
          "tue,",
          "wed,",
          "thu,",
          "fri,",
          "sat,",
          "sun,",
          "monday,",
          "tuesday,",
          "wednesday,",
          "thursday,",
          "friday,",
          "saturday,",
          "sunday,",
        ].contains(fields[0].lowercased().replacingOccurrences(of: ".,", with: ",")),
        let month = httpMonths.firstIndex(where: { $0.contains(fields[2].lowercased()) }),
        fields[5] == "GMT"
  else { return nil }
  guard let year = Int(fields[3]), year >= 1,
        let day = Int(fields[1]), day >= 1
  else { return nil }
  let leapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  guard day <= daysInMonth[month] else { return nil }
  let clock = fields[4].split(separator: ":")
  guard clock.count == 3,
        let hour = Int(clock[0]), (0 ..< 24).contains(hour),
        let minute = Int(clock[1]), (0 ..< 60).contains(minute),
        let second = Int(clock[2]), (0 ..< 60).contains(second)
  else { return nil }
  let monthNumber = String(month + 1)
  let iso = "\(fields[3])-\(monthNumber.count == 1 ? "0" : "")\(monthNumber)-\(fields[1])T\(fields[4])Z"
  return try? Date.ISO8601FormatStyle().parse(iso)
}

private let httpMonths = [
  ["jan", "january"], ["feb", "february"], ["mar", "march"], ["apr", "april"],
  ["may"], ["jun", "june"], ["jul", "july"], ["aug", "august"],
  ["sep", "september"], ["oct", "october"], ["nov", "november"], ["dec", "december"],
]
