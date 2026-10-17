import Synchronization

// The retryable outcome of racing an eviction: a dropped Callback resolves to
// this on deinit, and lazy materialization makes the caller's retry land.
struct UnfulfilledError: Error {}

final class Callback<Value>: Sendable {
  typealias Continuation = CheckedContinuation<Value, any Error>

  let state: Mutex<Continuation?>

  fileprivate init(_ cont: Continuation) {
    state = .init(cont)
  }

  func resume(with result: sending Result<Value, any Error>) {
    let cont = state.withLock { source -> Continuation? in
      let cont = source
      source = nil
      return cont
    }
    cont!.resume(with: result)
  }

  func resume(returning value: sending Value) {
    resume(with: .success(value))
  }

  func resume(throwing error: any Error) {
    resume(with: .failure(error))
  }

  // The body must stay caller-isolated (the store executor); an
  // @isolated(any) parameter would drop the dynamic isolation and run the
  // verb off-actor.
  func run(body: () async throws -> sending Value) async {
    do {
      let result = try await body()
      resume(returning: result)
    } catch {
      resume(throwing: error)
    }
  }

  deinit {
    state.withLock { cont in
      guard let cont else { return }
      cont.resume(throwing: UnfulfilledError())
    }
  }
}

func withCallback<T>(of type: T.Type = T.self, job: (Callback<T>) throws -> Void) async throws -> T {
  try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
    let callback = Callback(cont)
    do {
      try job(callback)
    } catch {
      callback.resume(throwing: error)
    }
  }
}
