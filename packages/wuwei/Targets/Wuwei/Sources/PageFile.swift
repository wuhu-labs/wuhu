import GRDBSQLite
import Synchronization

/// One addressable's inner database file as its SQLite sees it: pages written since the last seal, over sealed pages not yet durable, over the outer store's copy.
final class PageFile {
  static let pageSize = 4096

  let writable: Bool
  private let durable: (UInt32) throws -> [UInt8]?
  private(set) var pageCount: UInt32
  private var sealedPageCount: UInt32
  private var dirty: [UInt32: [UInt8]] = [:]
  private var unshipped: [(epoch: UInt64, pages: [UInt32: [UInt8]])] = []

  init(pageCount: UInt32, writable: Bool, durable: @escaping (UInt32) throws -> [UInt8]?) {
    self.pageCount = pageCount
    sealedPageCount = pageCount
    self.writable = writable
    self.durable = durable
  }

  var isDirty: Bool {
    !dirty.isEmpty || pageCount != sealedPageCount
  }

  func seal(_ epoch: UInt64) -> [UInt32: [UInt8]] {
    let pages = dirty
    dirty = [:]
    sealedPageCount = pageCount
    unshipped.append((epoch, pages))
    return pages
  }

  func markDurable(through epoch: UInt64) {
    unshipped.removeAll { $0.epoch <= epoch }
  }

  private func page(_ number: UInt32) throws -> [UInt8]? {
    if let page = dirty[number] { return page }
    for (_, pages) in unshipped.reversed() {
      if let page = pages[number] { return page }
    }
    return try durable(number)
  }

  fileprivate func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) -> Int32 {
    let number = UInt32(offset / Int64(Self.pageSize)) + 1
    let start = Int(offset % Int64(Self.pageSize))
    precondition(start + buffer.count <= Self.pageSize, "a read spans pages")
    guard number <= pageCount, let page = try? page(number) else {
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      return number <= pageCount ? SQLITE_IOERR_READ : SQLITE_IOERR_SHORT_READ
    }
    page[start ..< start + buffer.count].withUnsafeBytes { buffer.copyMemory(from: $0) }
    return SQLITE_OK
  }

  fileprivate func write(_ bytes: UnsafeRawBufferPointer, at offset: Int64) {
    precondition(bytes.count == Self.pageSize && offset % Int64(Self.pageSize) == 0, "a write is not one whole page")
    let number = UInt32(offset / Int64(Self.pageSize)) + 1
    dirty[number] = Array(bytes)
    pageCount = max(pageCount, number)
  }

  fileprivate func truncate(to size: Int64) {
    pageCount = UInt32(size / Int64(Self.pageSize))
    dirty = dirty.filter { $0.key <= pageCount }
  }
}

extension Connection {
  /// The inner database of the addressable `owner`, which `cell()` returns on it.
  convenience init(file: PageFile, owner: String) throws {
    registerVFS()
    let name = "wuwei:\(UInt(bitPattern: Unmanaged.passUnretained(file).toOpaque()))"
    try self.init(path: name, flags: file.writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY, vfs: "wuwei")
    try Self.prepare(handle)
    self.owner = owner
    try execute("PRAGMA temp_store = MEMORY")
    if file.writable {
      try execute("PRAGMA locking_mode = EXCLUSIVE")
      try execute("PRAGMA journal_mode = MEMORY")
    }
  }
}

private let registered = Mutex(false)

private func registerVFS() {
  registered.withLock { registered in
    guard !registered else { return }
    registered = true
    let vfs = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
    vfs.initialize(to: sqlite3_vfs_find(nil)!.pointee)
    vfs.pointee.iVersion = 1
    vfs.pointee.pNext = nil
    vfs.pointee.zName = UnsafePointer(cString("wuwei"))
    vfs.pointee.szOsFile = Int32(MemoryLayout<sqlite3_file>.stride + MemoryLayout<UnsafeRawPointer>.stride)
    vfs.pointee.pAppData = UnsafeMutableRawPointer(methods())
    vfs.pointee.xOpen = { vfs, name, file, flags, outFlags in
      // The name is "wuwei:<address of the PageFile>", made by Connection.init(file:).
      guard flags & SQLITE_OPEN_MAIN_DB != 0, let name, let address = UInt(String(cString: name).dropFirst("wuwei:".count)),
            let object = UnsafeRawPointer(bitPattern: address) else { return SQLITE_CANTOPEN }
      _ = Unmanaged<PageFile>.fromOpaque(object).retain()
      slot(file).storeBytes(of: object, as: UnsafeRawPointer.self)
      file!.pointee.pMethods = UnsafePointer(vfs!.pointee.pAppData.assumingMemoryBound(to: sqlite3_io_methods.self))
      outFlags?.pointee = flags
      return SQLITE_OK
    }
    vfs.pointee.xDelete = { _, _, _ in SQLITE_OK }
    vfs.pointee.xAccess = { _, _, _, out in
      out!.pointee = 0
      return SQLITE_OK
    }
    vfs.pointee.xFullPathname = { _, name, size, out in
      var index = 0
      while name![index] != 0, index < Int(size) - 1 {
        out![index] = name![index]
        index += 1
      }
      out![index] = 0
      return SQLITE_OK
    }
    sqlite3_vfs_register(vfs, 0)
  }
}

private func methods() -> UnsafeMutablePointer<sqlite3_io_methods> {
  let methods = UnsafeMutablePointer<sqlite3_io_methods>.allocate(capacity: 1)
  methods.initialize(to: sqlite3_io_methods())
  methods.pointee.iVersion = 1
  methods.pointee.xClose = { file in
    Unmanaged<PageFile>.fromOpaque(slot(file).load(as: UnsafeRawPointer.self)).release()
    return SQLITE_OK
  }
  methods.pointee.xRead = { file, buffer, count, offset in
    pageFile(file).read(into: UnsafeMutableRawBufferPointer(start: buffer, count: Int(count)), at: offset)
  }
  methods.pointee.xWrite = { file, bytes, count, offset in
    let file = pageFile(file)
    guard file.writable else { return SQLITE_READONLY }
    file.write(UnsafeRawBufferPointer(start: bytes, count: Int(count)), at: offset)
    return SQLITE_OK
  }
  methods.pointee.xTruncate = { file, size in
    pageFile(file).truncate(to: size)
    return SQLITE_OK
  }
  methods.pointee.xSync = { _, _ in SQLITE_OK }
  methods.pointee.xFileSize = { file, size in
    size!.pointee = Int64(pageFile(file).pageCount) * Int64(PageFile.pageSize)
    return SQLITE_OK
  }
  methods.pointee.xLock = { _, _ in SQLITE_OK }
  methods.pointee.xUnlock = { _, _ in SQLITE_OK }
  methods.pointee.xCheckReservedLock = { _, out in
    out!.pointee = 0
    return SQLITE_OK
  }
  methods.pointee.xFileControl = { _, _, _ in SQLITE_NOTFOUND }
  methods.pointee.xSectorSize = { _ in Int32(PageFile.pageSize) }
  methods.pointee.xDeviceCharacteristics = { _ in SQLITE_IOCAP_ATOMIC4K | SQLITE_IOCAP_SAFE_APPEND | SQLITE_IOCAP_POWERSAFE_OVERWRITE }
  return methods
}

private func slot(_ file: UnsafeMutablePointer<sqlite3_file>?) -> UnsafeMutableRawPointer {
  UnsafeMutableRawPointer(file!).advanced(by: MemoryLayout<sqlite3_file>.stride)
}

private func pageFile(_ file: UnsafeMutablePointer<sqlite3_file>?) -> PageFile {
  Unmanaged<PageFile>.fromOpaque(slot(file).load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

// Extended result codes are macros Swift can't import.
private let SQLITE_IOERR_READ = SQLITE_IOERR | (1 << 8)
private let SQLITE_IOERR_SHORT_READ = SQLITE_IOERR | (2 << 8)

private func cString(_ string: String) -> UnsafeMutablePointer<CChar> {
  let bytes = Array(string.utf8CString)
  let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
  pointer.initialize(from: bytes, count: bytes.count)
  return pointer
}
