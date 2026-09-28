import {
  assertionHeaders,
  base64,
  base64Url,
  generateKey,
  type KeyAlgorithm,
  mintAssertion,
} from './assertion.ts'

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message)
}

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

function standardBase64Decoded(text: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0))
}

function base64UrlDecoded(segment: string): Uint8Array<ArrayBuffer> {
  let standard = segment.replaceAll('-', '+').replaceAll('_', '/')
  while (standard.length % 4 !== 0) standard += '='
  return standardBase64Decoded(standard)
}

Deno.test('headers are byte-identical to the Swift assertion header table', () => {
  assertEquals(
    assertionHeaders.ed25519,
    'eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9',
  )
  assertEquals(assertionHeaders.p256, 'eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9')
})

Deno.test('labels use standard base64, segments use unpadded base64url', () => {
  const bytes = new Uint8Array([0xfb, 0xef])
  assertEquals(base64(bytes), '++8=')
  assertEquals(base64Url(bytes), '--8')
})

async function verifies(algorithm: KeyAlgorithm): Promise<void> {
  const space = 'sha256:' + 'c'.repeat(64)
  const key = await generateKey(algorithm)
  assert(
    key.label.startsWith(`${algorithm}:`),
    'label carries the algorithm tag',
  )
  const rawPublic = standardBase64Decoded(
    key.label.slice(algorithm.length + 1),
  )
  assertEquals(rawPublic.length, algorithm === 'ed25519' ? 32 : 65)

  const assertion = await mintAssertion(key, space, 4102444800.7)
  const parts = assertion.split('.')
  assertEquals(parts.length, 3)
  assert(
    parts.every((part) => !/[+/=]/.test(part)),
    'segments must be unpadded base64url',
  )
  assertEquals(parts[0], assertionHeaders[algorithm])
  const payload = JSON.parse(
    new TextDecoder().decode(base64UrlDecoded(parts[1]!)),
  ) as Record<string, unknown>
  assertEquals(payload, { key: key.label, space, exp: 4102444800 })
  const signature = base64UrlDecoded(parts[2]!)
  assertEquals(signature.length, 64)

  const params: AlgorithmIdentifier | EcKeyImportParams =
    algorithm === 'ed25519' ? 'Ed25519' : { name: 'ECDSA', namedCurve: 'P-256' }
  const publicKey = await crypto.subtle.importKey(
    'raw',
    rawPublic,
    params,
    true,
    ['verify'],
  )
  const verified = await crypto.subtle.verify(
    algorithm === 'ed25519' ? 'Ed25519' : { name: 'ECDSA', hash: 'SHA-256' },
    publicKey,
    signature,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  )
  assert(verified, 'signature must verify against the labeled public key')
}

Deno.test('an ed25519 assertion round-trips', () => verifies('ed25519'))
Deno.test('a p256 assertion round-trips with a raw 64-byte signature', () =>
  verifies('p256'))
