export type KeyAlgorithm = 'ed25519' | 'p256'

export interface DeviceKey {
  algorithm: KeyAlgorithm
  privateKey: CryptoKey
  label: string
}

const encoder = new TextEncoder()

// Pubkey labels use standard base64 with padding; JWT segments use unpadded
// base64url. Mixing the two conventions produces a silent 401 (see
// SpaceContract SPEC.md).
export function base64(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

export function base64Url(bytes: Uint8Array): string {
  return base64(bytes)
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '')
}

// Swift's verifier matches the raw header segment against these exact bytes:
// same key order, no spaces. Any drift is a silent 401.
export const assertionHeaders: Record<KeyAlgorithm, string> = {
  ed25519: base64Url(encoder.encode('{"alg":"EdDSA","typ":"JWT"}')),
  p256: base64Url(encoder.encode('{"alg":"ES256","typ":"JWT"}')),
}

const signParams: Record<
  KeyAlgorithm,
  AlgorithmIdentifier | EcdsaParams
> = {
  ed25519: 'Ed25519',
  p256: { name: 'ECDSA', hash: 'SHA-256' },
}

export async function generateKey(algorithm: KeyAlgorithm): Promise<DeviceKey> {
  const params: AlgorithmIdentifier | EcKeyGenParams = algorithm === 'ed25519'
    ? 'Ed25519'
    : { name: 'ECDSA', namedCurve: 'P-256' }
  const pair = (await crypto.subtle.generateKey(params, false, [
    'sign',
  ])) as CryptoKeyPair
  const raw = new Uint8Array(
    await crypto.subtle.exportKey('raw', pair.publicKey),
  )
  return {
    algorithm,
    privateKey: pair.privateKey,
    label: `${algorithm}:${base64(raw)}`,
  }
}

export async function generateDeviceKey(): Promise<DeviceKey> {
  try {
    return await generateKey('ed25519')
  } catch {
    return await generateKey('p256')
  }
}

export async function signBytes(
  key: DeviceKey,
  bytes: Uint8Array<ArrayBuffer>,
): Promise<Uint8Array<ArrayBuffer>> {
  return new Uint8Array(
    await crypto.subtle.sign(signParams[key.algorithm], key.privateKey, bytes),
  )
}

export async function mintAssertion(
  key: DeviceKey,
  space: string,
  expiresAt: number,
): Promise<string> {
  const payload = { key: key.label, space, exp: Math.floor(expiresAt) }
  const signingInput = `${assertionHeaders[key.algorithm]}.${
    base64Url(encoder.encode(JSON.stringify(payload)))
  }`
  const signature = await signBytes(key, encoder.encode(signingInput))
  return `${signingInput}.${base64Url(signature)}`
}
