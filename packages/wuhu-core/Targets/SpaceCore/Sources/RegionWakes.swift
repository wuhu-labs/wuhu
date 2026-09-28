import GRDB

func regionWakes(
  _ regions: [any DatabaseRegionConvertible],
  in writer: any DatabaseWriter,
  onError: @escaping @Sendable (any Error) -> Void = { _ in },
) -> AsyncStream<Void> {
  AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
    let cancellable = DatabaseRegionObservation(tracking: regions).start(
      in: writer,
      onError: { error in
        onError(error)
        continuation.finish()
      },
      onChange: { _ in continuation.yield(()) },
    )
    continuation.onTermination = { _ in cancellable.cancel() }
  }
}
