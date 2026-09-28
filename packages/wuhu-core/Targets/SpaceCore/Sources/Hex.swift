private let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

func hexEncoded(_ bytes: some Sequence<UInt8>) -> String {
  var out: [UInt8] = []
  out.reserveCapacity(bytes.underestimatedCount * 2)
  for byte in bytes {
    out.append(hexDigits[Int(byte >> 4)])
    out.append(hexDigits[Int(byte & 0x0F)])
  }
  return String(decoding: out, as: UTF8.self)
}
