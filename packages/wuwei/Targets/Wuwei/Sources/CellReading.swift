public protocol CellReading {
  func cell<C: Cell>(_ id: C.ID) -> C
}

extension CellContext: CellReading {}
extension JobContext: CellReading {}
extension Reader: CellReading {}
