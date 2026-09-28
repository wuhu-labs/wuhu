import { qrModules, qrSvgPath } from './qr.ts'

// The decoder is only reachable when npm packages resolve (a node_modules tree,
// or --node-modules-dir=none --node-modules-linker=isolated); the structural
// tests must still run where it is not.
const zxing = await import('npm:zxing-wasm@^2.2.0/reader').catch(() => null)

function assert(ok: boolean, message: string): void {
  if (!ok) throw new Error(message)
}

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const enrollUrl = 'https://origin.example.com:5530/_/enroll#token=jt_' +
  '7fbc1d2e3a4b5c6d' + '&space=spc_' + 'a1'.repeat(16)

function finderIsIntact(
  modules: boolean[][],
  top: number,
  left: number,
): boolean {
  for (let r = 0; r < 7; r++) {
    for (let c = 0; c < 7; c++) {
      const ring = Math.max(Math.abs(r - 3), Math.abs(c - 3))
      if (modules[top + r][left + c] !== (ring !== 2)) return false
    }
  }
  return true
}

Deno.test('qrModules encodes short text as a version 1 symbol', () => {
  const modules = qrModules('HELLO WORLD')
  assertEquals(modules.length, 21)
  assert(modules.every((row) => row.length === 21), 'matrix is not square')

  assert(finderIsIntact(modules, 0, 0), 'top-left finder')
  assert(finderIsIntact(modules, 0, 14), 'top-right finder')
  assert(finderIsIntact(modules, 14, 0), 'bottom-left finder')

  for (let i = 8; i < 13; i++) {
    assertEquals(modules[6][i], i % 2 === 0)
    assertEquals(modules[i][6], i % 2 === 0)
  }
})

Deno.test('qrModules fits a long enrollment URL within version 15', () => {
  assert(enrollUrl.length > 85, `url too short: ${enrollUrl.length}`)
  const modules = qrModules(enrollUrl)
  const size = modules.length
  assert((size - 17) % 4 === 0, `size ${size} is not 4v+17`)
  const version = (size - 17) / 4
  assert(version >= 1 && version <= 15, `version ${version} out of range`)
  assert(modules.every((row) => row.length === size), 'matrix is not square')
})

Deno.test('the two format-info copies agree', () => {
  for (const text of ['HELLO WORLD', enrollUrl]) {
    const modules = qrModules(text)
    const n = modules.length
    for (let i = 0; i < 15; i++) {
      const first = i < 6
        ? modules[i][8]
        : i === 6
        ? modules[7][8]
        : i === 7
        ? modules[8][8]
        : i === 8
        ? modules[8][7]
        : modules[8][14 - i]
      const second = i < 8 ? modules[8][n - 1 - i] : modules[n - 15 + i][8]
      assertEquals(first, second)
    }
    assert(modules[n - 8][8], 'dark module missing')
  }
})

Deno.test('qrSvgPath emits one run per horizontal stretch of dark modules', () => {
  const path = qrSvgPath([[true, true, false, true]])
  assertEquals(path, 'M0 0h2v1h-2zM3 0h1v1h-1z')
  assertEquals(qrSvgPath([[false, false]]), '')
})

Deno.test('qrModules refuses text beyond version 15', () => {
  const version15Bytes = 412
  qrModules('x'.repeat(version15Bytes))
  let threw = false
  try {
    qrModules('x'.repeat(version15Bytes + 1))
  } catch {
    threw = true
  }
  assert(threw, 'expected an overflow error')
})

function rasterize(modules: boolean[][]): ImageData {
  const scale = 8
  const quiet = 4
  const n = modules.length
  const width = (n + quiet * 2) * scale
  const data = new Uint8ClampedArray(width * width * 4).fill(255)
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) {
      if (!modules[r][c]) continue
      for (let y = 0; y < scale; y++) {
        for (let x = 0; x < scale; x++) {
          const px = ((quiet + r) * scale + y) * width + (quiet + c) * scale + x
          data[px * 4] = 0
          data[px * 4 + 1] = 0
          data[px * 4 + 2] = 0
        }
      }
    }
  }
  return { data, width, height: width, colorSpace: 'srgb' } as ImageData
}

// zxing-wasm resolves its .wasm against a CDN by default; under `deno test` the
// package lives in the module cache, whose path only surfaces through the stack
// of a call made from inside the package.
function wasmUrl(name: string): string {
  const stack = new Error().stack ?? ''
  const url = stack.match(/file:\/\/[^\s)]*zxing-wasm[^\s)]*\/dist\//)?.[0]
  if (!url) throw new Error(`zxing-wasm dist not found in stack:\n${stack}`)
  return `${url}reader/${name}`
}

Deno.test({
  name: 'qrModules round-trips through a QR decoder',
  ignore: zxing === null,
  async fn() {
    const { prepareZXingModule, readBarcodes } = zxing!
    await prepareZXingModule({
      overrides: { locateFile: (name: string) => wasmUrl(name) },
      fireImmediately: true,
    })
    for (const text of ['HELLO WORLD', enrollUrl]) {
      const results = await readBarcodes(rasterize(qrModules(text)), {
        formats: ['QRCode'],
      })
      assertEquals(results.length, 1)
      assertEquals(results[0].text, text)
    }
  },
})
