const MAX_VERSION = 15

// [ecPerBlock, group1Blocks, group1DataWords, group2Blocks, group2DataWords]
const BLOCKS_M: readonly (readonly number[])[] = [
  [10, 1, 16, 0, 0],
  [16, 1, 28, 0, 0],
  [26, 1, 44, 0, 0],
  [18, 2, 32, 0, 0],
  [24, 2, 43, 0, 0],
  [16, 4, 27, 0, 0],
  [18, 4, 31, 0, 0],
  [22, 2, 38, 2, 39],
  [22, 3, 36, 2, 37],
  [26, 4, 43, 1, 44],
  [30, 1, 50, 4, 51],
  [22, 6, 36, 2, 37],
  [22, 8, 37, 1, 38],
  [24, 4, 40, 5, 41],
  [24, 5, 41, 5, 42],
]

const ALIGNMENT: readonly (readonly number[])[] = [
  [],
  [6, 18],
  [6, 22],
  [6, 26],
  [6, 30],
  [6, 34],
  [6, 22, 38],
  [6, 24, 42],
  [6, 26, 46],
  [6, 28, 50],
  [6, 30, 54],
  [6, 32, 58],
  [6, 34, 62],
  [6, 26, 46, 66],
  [6, 26, 48, 70],
]

const EXP = new Uint8Array(512)
const LOG = new Uint8Array(256)
for (let i = 0, x = 1; i < 255; i++) {
  EXP[i] = x
  LOG[x] = i
  x = x << 1
  if (x & 0x100) x ^= 0x11d
}
for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255]

function mul(a: number, b: number): number {
  return a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]]
}

function generator(degree: number): Uint8Array {
  let poly = new Uint8Array([1])
  for (let d = 0; d < degree; d++) {
    const next = new Uint8Array(poly.length + 1)
    for (let i = 0; i < poly.length; i++) {
      next[i] ^= poly[i]
      next[i + 1] ^= mul(poly[i], EXP[d])
    }
    poly = next
  }
  return poly
}

function remainder(data: Uint8Array, degree: number): Uint8Array {
  const gen = generator(degree)
  const out = new Uint8Array(degree)
  for (const byte of data) {
    const factor = byte ^ out[0]
    out.copyWithin(0, 1)
    out[degree - 1] = 0
    for (let i = 0; i < degree; i++) out[i] ^= mul(gen[i + 1], factor)
  }
  return out
}

function dataCapacity(version: number): number {
  const [, b1, d1, b2, d2] = BLOCKS_M[version - 1]
  return b1 * d1 + b2 * d2
}

function pickVersion(byteLength: number): number {
  for (let v = 1; v <= MAX_VERSION; v++) {
    const header = 4 + (v < 10 ? 8 : 16)
    if (header + byteLength * 8 <= dataCapacity(v) * 8) return v
  }
  throw new Error(`qr: ${byteLength} bytes exceed version ${MAX_VERSION}`)
}

function encodeData(bytes: Uint8Array, version: number): Uint8Array {
  const bits: number[] = []
  const push = (value: number, width: number) => {
    for (let i = width - 1; i >= 0; i--) bits.push((value >> i) & 1)
  }
  push(0b0100, 4)
  push(bytes.length, version < 10 ? 8 : 16)
  for (const byte of bytes) push(byte, 8)
  const capacity = dataCapacity(version)
  for (let i = 0; i < 4 && bits.length < capacity * 8; i++) bits.push(0)
  while (bits.length % 8 !== 0) bits.push(0)
  const words = new Uint8Array(capacity)
  for (let i = 0; i < bits.length; i += 8) {
    let byte = 0
    for (let b = 0; b < 8; b++) byte = (byte << 1) | bits[i + b]
    words[i / 8] = byte
  }
  for (let i = bits.length / 8; i < capacity; i++) {
    words[i] = (i - bits.length / 8) % 2 === 0 ? 0xec : 0x11
  }
  return words
}

function interleave(words: Uint8Array, version: number): Uint8Array {
  const [ec, b1, d1, b2, d2] = BLOCKS_M[version - 1]
  const data: Uint8Array[] = []
  const parity: Uint8Array[] = []
  let at = 0
  for (let i = 0; i < b1 + b2; i++) {
    const size = i < b1 ? d1 : d2
    const block = words.subarray(at, at + size)
    at += size
    data.push(block)
    parity.push(remainder(block, ec))
  }
  const out: number[] = []
  for (let i = 0; i < Math.max(d1, d2); i++) {
    for (const block of data) if (i < block.length) out.push(block[i])
  }
  for (let i = 0; i < ec; i++) for (const block of parity) out.push(block[i])
  return new Uint8Array(out)
}

type Grid = boolean[][]

function square(size: number): Grid {
  return Array.from({ length: size }, () => new Array(size).fill(false))
}

function drawFunctions(modules: Grid, fixed: Grid, version: number): void {
  const n = modules.length
  const set = (r: number, c: number, dark: boolean) => {
    modules[r][c] = dark
    fixed[r][c] = true
  }
  const finder = (row: number, col: number) => {
    for (let r = -1; r <= 7; r++) {
      for (let c = -1; c <= 7; c++) {
        const rr = row + r, cc = col + c
        if (rr < 0 || rr >= n || cc < 0 || cc >= n) continue
        const ring = Math.max(Math.abs(r - 3), Math.abs(c - 3))
        set(rr, cc, ring !== 2 && ring <= 3)
      }
    }
  }
  finder(0, 0)
  finder(0, n - 7)
  finder(n - 7, 0)
  for (let i = 8; i < n - 8; i++) {
    const dark = i % 2 === 0
    set(6, i, dark)
    set(i, 6, dark)
  }
  const centers = ALIGNMENT[version - 1]
  for (const row of centers) {
    for (const col of centers) {
      if (row === 6 && col === 6) continue
      if (row === 6 && col === centers[centers.length - 1]) continue
      if (col === 6 && row === centers[centers.length - 1]) continue
      for (let r = -2; r <= 2; r++) {
        for (let c = -2; c <= 2; c++) {
          const ring = Math.max(Math.abs(r), Math.abs(c))
          set(row + r, col + c, ring !== 1)
        }
      }
    }
  }
  for (let i = 0; i <= 8; i++) {
    if (i !== 6) {
      fixed[8][i] = true
      fixed[i][8] = true
    }
  }
  for (let i = 0; i < 8; i++) {
    fixed[8][n - 1 - i] = true
    fixed[n - 1 - i][8] = true
  }
  set(n - 8, 8, true)
  if (version >= 7) {
    let bits = version
    for (let i = 0; i < 12; i++) {
      bits = (bits << 1) ^ ((bits >>> 11) * 0x1f25)
    }
    const value = (version << 12) | bits
    for (let i = 0; i < 18; i++) {
      const dark = ((value >> i) & 1) === 1
      const a = n - 11 + (i % 3), b = Math.floor(i / 3)
      set(b, a, dark)
      set(a, b, dark)
    }
  }
}

function drawFormat(modules: Grid, mask: number): void {
  const n = modules.length
  let bits = mask
  for (let i = 0; i < 10; i++) bits = (bits << 1) ^ ((bits >>> 9) * 0x537)
  const value = ((mask << 10) | bits) ^ 0x5412
  const bit = (i: number) => ((value >> i) & 1) === 1
  for (let i = 0; i <= 5; i++) modules[i][8] = bit(i)
  modules[7][8] = bit(6)
  modules[8][8] = bit(7)
  modules[8][7] = bit(8)
  for (let i = 9; i < 15; i++) modules[8][14 - i] = bit(i)
  for (let i = 0; i < 8; i++) modules[8][n - 1 - i] = bit(i)
  for (let i = 8; i < 15; i++) modules[n - 15 + i][8] = bit(i)
}

function placeCodewords(modules: Grid, fixed: Grid, words: Uint8Array): void {
  const n = modules.length
  let bit = 0
  let upward = true
  const total = words.length * 8
  for (let right = n - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5
    for (let step = 0; step < n; step++) {
      const row = upward ? n - 1 - step : step
      for (const col of [right, right - 1]) {
        if (fixed[row][col]) continue
        modules[row][col] = bit < total &&
          ((words[bit >> 3] >> (7 - (bit & 7))) & 1) === 1
        bit++
      }
    }
    upward = !upward
  }
}

function maskAt(mask: number, r: number, c: number): boolean {
  switch (mask) {
    case 0:
      return (r + c) % 2 === 0
    case 1:
      return r % 2 === 0
    case 2:
      return c % 3 === 0
    case 3:
      return (r + c) % 3 === 0
    case 4:
      return (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0
    case 5:
      return ((r * c) % 2) + ((r * c) % 3) === 0
    case 6:
      return (((r * c) % 2) + ((r * c) % 3)) % 2 === 0
    default:
      return (((r + c) % 2) + ((r * c) % 3)) % 2 === 0
  }
}

const FINDER_RUN = [true, false, true, true, true, false, true]

function finderLikeCount(line: boolean[], at: number): number {
  for (let i = 0; i < 7; i++) if (line[at + i] !== FINDER_RUN[i]) return 0
  const clear = (part: boolean[]) => part.length === 4 && !part.some(Boolean)
  const before = clear(line.slice(at - 4, at)) ? 1 : 0
  const after = clear(line.slice(at + 7, at + 11)) ? 1 : 0
  return before + after
}

function penalty(modules: Grid): number {
  const n = modules.length
  let score = 0
  let dark = 0
  const lines: boolean[][] = []
  for (let i = 0; i < n; i++) {
    lines.push(modules[i])
    lines.push(modules.map((row) => row[i]))
  }
  for (const line of lines) {
    let run = 1
    for (let i = 1; i <= n; i++) {
      if (i < n && line[i] === line[i - 1]) {
        run++
        continue
      }
      if (run >= 5) score += 3 + (run - 5)
      run = 1
    }
    for (let i = 0; i + 7 <= n; i++) {
      score += 40 * finderLikeCount(line, i)
    }
  }
  for (let r = 0; r + 1 < n; r++) {
    for (let c = 0; c + 1 < n; c++) {
      const a = modules[r][c]
      if (
        a === modules[r][c + 1] && a === modules[r + 1][c] &&
        a === modules[r + 1][c + 1]
      ) score += 3
    }
  }
  for (const row of modules) for (const cell of row) if (cell) dark++
  const ratio = (dark * 100) / (n * n)
  score += Math.floor(Math.abs(ratio - 50) / 5) * 10
  return score
}

export function qrModules(text: string): boolean[][] {
  const bytes = new TextEncoder().encode(text)
  const version = pickVersion(bytes.length)
  const words = interleave(encodeData(bytes, version), version)
  const size = version * 4 + 17
  const base = square(size)
  const fixed = square(size)
  drawFunctions(base, fixed, version)
  placeCodewords(base, fixed, words)

  let best = base
  let bestScore = Infinity
  for (let mask = 0; mask < 8; mask++) {
    const candidate = base.map((row) => row.slice())
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        if (!fixed[r][c] && maskAt(mask, r, c)) {
          candidate[r][c] = !candidate[r][c]
        }
      }
    }
    drawFormat(candidate, mask)
    const score = penalty(candidate)
    if (score < bestScore) {
      bestScore = score
      best = candidate
    }
  }
  return best
}

export function qrSvgPath(modules: boolean[][]): string {
  const parts: string[] = []
  for (let r = 0; r < modules.length; r++) {
    const row = modules[r]
    for (let c = 0; c < row.length; c++) {
      if (!row[c]) continue
      let width = 1
      while (c + width < row.length && row[c + width]) width++
      parts.push(`M${c} ${r}h${width}v1h-${width}z`)
      c += width - 1
    }
  }
  return parts.join('')
}
